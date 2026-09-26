//! Deterministic host-only recovery inputs, never execution authority.
use crate::{DIGEST, Result, canonical_root, error};
use arkdeck_hoststore::job_journal_events::{self as events, Envelope};
use arkdeck_hoststore::{AdmissionVerdict, JobRecord, JobStore, JournalWriter, inspect_journal};
use arkdeck_platform::HostDirectory;
use serde_json::{Value, json};
use std::{fs, path::Path};

const NOW: &str = "2026-09-26T00:00:00Z";
pub const VERSION: &str = "rust-recovery-fixture-v1";

/// A fresh empty directory is mandatory. Never extends an installed/old fixture.
/// History follows the existing direct-repository terminal-history benchmark:
/// terminal snapshots, no provider execution and no journals to recover.
pub fn seed(root: &Path, workload: &str, count: usize) -> Result<Value> {
    if !(2..=10_000).contains(&count) || !matches!(workload, "journal" | "history") {
        return Err("recovery workload must be journal/history with count 2..10000".into());
    }
    let root = canonical_root(root)?;
    if fs::read_dir(&root).map_err(error)?.next().is_some() {
        return Err("recovery seed requires an empty root".into());
    }
    let directory = HostDirectory::open(&root).map_err(error)?;
    let _lock = directory
        .lock_document(".recovery-seed.lock")
        .map_err(error)?;
    directory.private_child("jobs-state").map_err(error)?;
    let jobs = JobStore::open_owner(&root.join("jobs-state")).map_err(error)?;
    let job_count = if workload == "journal" { 1 } else { count };
    for index in 0..job_count {
        let id = format!("job-recovery-{index:05}");
        let state = if workload == "journal" {
            "preflight"
        } else {
            "succeeded"
        };
        let value = json!({
            "jobID": id, "request": {
                "documentType":"runtime-operation-request", "schemaVersion":"1.0.0",
                "requestId":id, "idempotencyKey":id,
                "target":{"targetId":"host"}, "operation":{"id":"observe.device","version":1},
                "inputs":{}, "requestedOutputs":[]
            },
            "operationReference":"observe.device@1", "catalogDigest":DIGEST,
            "providerID":"hdc", "createdAtUTC":NOW, "state":state,
            "actualEffect":"readOnly", "outcomeUnknown":false, "timeline":[], "skipReasons":{}
        });
        let record =
            JobRecord::decode(&serde_json::to_vec(&value).map_err(error)?).map_err(error)?;
        if jobs.admit(&record, DIGEST).map_err(error)? != AdmissionVerdict::Admitted {
            return Err("fixture identity already admitted".into());
        }
        jobs.persist(&record, NOW).map_err(error)?;
        if workload == "journal" {
            let job_root = root.join("jobs-state/jobs").join(&id);
            let mut writer = JournalWriter::open(&job_root, true).map_err(error)?;
            for sequence in 0..count {
                let envelope = Envelope {
                    event_id: format!("event-{sequence:05}"),
                    sequence: sequence as i64,
                    session_id: "session-recovery".into(),
                    job_id: id.clone(),
                    timestamp: NOW.into(),
                };
                let event = match sequence {
                    0 => events::job_created(&envelope, "simulated", "standardAgent", "CORE-1.0.0"),
                    1 => {
                        events::state_transition(&envelope, "queued", "preflight", "fixture", None)
                    }
                    _ => json!({"schemaVersion":"1.0.0", "eventId":envelope.event_id,
                        "sequence":sequence, "sessionId":envelope.session_id, "jobId":id,
                        "timestamp":NOW,"kind":"warning", "payload":{
                            "code":"fixture", "message":"bounded historical warning", "details":{}}}),
                };
                writer.append(&event).map_err(error)?;
            }
            drop(writer);
            let facts = inspect_journal(&job_root).map_err(error)?;
            if facts.event_count != count
                || facts.has_torn_tail
                || facts.current_state.as_deref() != Some("preflight")
            {
                return Err("seed journal validation failed".into());
            }
        }
    }
    let manifest = json!({"fixtureVersion":VERSION,"workload":workload,
        "jobCount":job_count,"activeJobCount":if workload == "journal" {1} else {0},
        "journalEventCount":if workload == "journal" {count} else {0},
        "seedTimestamp":NOW,"providerDispatchCount":0});
    directory
        .publish_document(
            "recovery-fixture.json",
            &serde_json::to_vec(&manifest).map_err(error)?,
            4096,
        )
        .map_err(error)?;
    Ok(manifest)
}
