//! Swift `RuntimeSessionPublicationWriter` for the Jobs this Runtime runs. At
//! its terminal boundary a Job becomes a formal Session under the configured
//! Sessions root, derived only from its durable record and Journal: the
//! Manifest proposal beside the Job, the Journal's `finalized` record, the
//! Session tree with a byte-identical Journal copy, the outcome audit, the
//! write-once Manifest and the catalog entry; and, whatever happened, the
//! ownership marker the Job record keeps.
//!
//! As in Swift, a restart never resumes a publication and nothing retries
//! one; reconciliation stays unported (L.1 item 13).
use crate::job_journal_events::{self as events, Envelope};
use crate::job_journal_replay::ReplayFacts;
use crate::job_journal_writer::JournalWriter;
use crate::job_record::JobRecord;
use crate::session_owner::SessionStore;
use arkdeck_contract::sha256_hex;
use arkdeck_platform::{DocumentPublishError, HostDirectory, host_gregorian_timestamp};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::Mutex;

const APP_VERSION: &str = "ArkDeckKit-M1-006";
const PLATFORM_PROFILE: &str = "PLATFORM-MACOS@0.2.0";
/// Swift `SessionManifestDocument.maximumCanonicalBytes`, which is also a
/// publication claim's finalization headroom.
const MAXIMUM_MANIFEST: usize = 16 * 1024 * 1024;
const MAXIMUM_JOURNAL: usize = 64 * 1024 * 1024;
/// Swift `SessionArtifactPublicationBarrier`'s shards.
const SHARDS: &str = "0123456789abcdef";
const PROPOSAL: &str = "session-manifest.proposal.json";

/// What Swift `HostStorageProbing` reports about a Sessions root's volume.
pub struct StorageSnapshot {
    pub volume_identity: String,
    pub available_bytes: u64,
    pub read_only: bool,
}

/// Swift `HostStorageProbing`.
pub trait StorageProbe: Sync {
    fn snapshot(&self, root: &HostDirectory) -> io::Result<StorageSnapshot>;
}

/// Swift `SystemHostStorageProbe`: the held root's file system.
pub struct SystemStorageProbe;

impl StorageProbe for SystemStorageProbe {
    fn snapshot(&self, root: &HostDirectory) -> io::Result<StorageSnapshot> {
        let capacity = root.export_capacity()?;
        Ok(StorageSnapshot {
            volume_identity: capacity.facts.volume_identity,
            available_bytes: capacity.available_bytes,
            read_only: capacity.read_only,
        })
    }
}

/// Swift `HostStorageCoordinator`'s active claims in this process: each
/// admitted publication's soft bytes on its volume, held until its receipt.
/// As in Swift, only a refused composition releases a claim early; any other
/// stop leaves it held.
#[derive(Default)]
pub struct StorageClaims(Mutex<BTreeMap<String, (String, u64)>>);

impl StorageClaims {
    /// Swift `admitUnchecked` for a light writer.
    fn admit(&self, claim: &str, volume: &str, bytes: u64, snapshot: &StorageSnapshot) -> bool {
        let mut claims = self
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if snapshot.volume_identity != volume || snapshot.read_only || claims.contains_key(claim) {
            return false;
        }
        let held = claims
            .values()
            .filter(|(held, _)| held == volume)
            .fold(0_u64, |sum, (_, bytes)| sum.saturating_add(*bytes));
        match held.checked_add(bytes) {
            Some(required) if required <= snapshot.available_bytes => {
                claims.insert(claim.into(), (volume.into(), bytes));
                true
            }
            _ => false,
        }
    }

    fn release(&self, claim: &str) {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(claim);
    }
}

/// Swift `RuntimeSessionPublicationWriter` over the Session owner this
/// composition holds.
pub struct SessionPublisher<'a> {
    pub sessions: &'a SessionStore,
    pub claims: &'a StorageClaims,
    pub probe: &'a dyn StorageProbe,
}

/// Why a publication stopped short of its receipt.
struct Stop {
    reason: &'static str,
    detail: String,
}

fn stop(reason: &'static str, detail: impl Into<String>) -> Stop {
    Stop {
        reason,
        detail: detail.into(),
    }
}

/// Swift's catch-all: anything the composer did not name is the storage's.
fn storage(detail: impl Into<String>) -> Stop {
    stop("storageUnavailable", detail)
}

/// Swift's rendering of `SessionStorageError.writeFailed`.
fn write_failed(path: &Path, error: &io::Error) -> Stop {
    storage(format!(
        "writeFailed(path: \"{}\", errno: {})",
        path.display(),
        error.raw_os_error().unwrap_or(0)
    ))
}

fn publish_failed(path: &Path, error: DocumentPublishError) -> Stop {
    match error {
        DocumentPublishError::BeforePublication(error)
        | DocumentPublishError::OutcomeUnknown(error) => write_failed(path, &error),
    }
}

impl SessionPublisher<'_> {
    /// Swift `publish`: the marker this Job's record keeps, whatever
    /// happened. A marker that already holds its receipt stands.
    pub(crate) fn publish(
        &self,
        record: &JobRecord,
        journal: &mut JournalWriter,
        job_directory: &Path,
        now: &str,
    ) -> Value {
        if let Some(existing) = record
            .session_publication()
            .filter(|marker| marker.get("receipt").is_some())
        {
            return existing.clone();
        }
        self.attempt(record, journal, job_directory, now)
            .unwrap_or_else(|stopped| refused(record, &stopped))
    }

    /// Swift `attempt`: claim, compose, seal, create, copy, publish,
    /// register, receipt, release.
    fn attempt(
        &self,
        record: &JobRecord,
        journal: &mut JournalWriter,
        job_directory: &Path,
        now: &str,
    ) -> Result<Value, Stop> {
        let (root_path, policy_generation, _) =
            self.sessions.publication_status().map_err(storage)?;
        let root = HostDirectory::open(&root_path).map_err(|e| write_failed(&root_path, &e))?;
        let facts = root
            .export_facts()
            .map_err(|e| write_failed(&root_path, &e))?;
        let (year, month) = utc_month(record.created())
            .ok_or_else(|| stop("sourceIntegrityFailed", "Job creation time is unreadable"))?;
        let session_id = format!("session-{}", record.job_id);
        let mut marker = Map::from_iter([
            ("sessionID".into(), json!(session_id)),
            ("catalogDigest".into(), json!(record.catalog_digest())),
            (
                "policyGeneration".into(),
                json!(policy_generation.to_string()),
            ),
            (
                "root".into(),
                json!({"path": foundation_path(&root_path), "device": facts.device.to_string(),
                    "inode": facts.inode.to_string(), "volumeIdentity": facts.volume_identity}),
            ),
            (
                "relativeSessionPath".into(),
                json!(format!("{year}/{month}/{session_id}")),
            ),
            ("claims".into(), json!([])),
            ("phase".into(), json!("awaitingStorage")),
        ]);

        // 1. Metadata and finalization headroom before anything is created.
        let journal_path = job_directory.join("journal.jsonl");
        let journal_bytes =
            std::fs::read(&journal_path).map_err(|e| write_failed(&journal_path, &e))?;
        let replayed = events_of(&journal_bytes)?;
        let metadata = (journal_bytes.len() as u64).max(1) + 64 * 1024;
        let claim = format!("session-publication-{}", record.job_id);
        let admission = uuid().map_err(|e| write_failed(&root_path, &e))?;
        let snapshot = self
            .probe
            .snapshot(&root)
            .map_err(|e| write_failed(&root_path, &e))?;
        if !self.claims.admit(
            &claim,
            &facts.volume_identity,
            metadata + MAXIMUM_MANIFEST as u64,
            &snapshot,
        ) {
            return Ok(Value::Object(marker));
        }
        marker.insert(
            "claims".into(),
            json!([{"volumeIdentity": facts.volume_identity, "claimID": claim,
                "admissionGeneration": admission, "writerClass": "light",
                "metadataHeadroomBytes": metadata.to_string(),
                "finalizationHeadroomBytes": MAXIMUM_MANIFEST.to_string(),
                "remainingGrowthBytes": "0"}]),
        );

        // 2. A Job whose facts cannot render the current contract never
        //    creates a Session directory at all.
        let completed = record.finished_at().unwrap_or(now).to_owned();
        let replay = journal.facts();
        let manifest = match compose(record, &replayed, &replay, &completed) {
            Ok(manifest) => manifest,
            Err(refusal) => {
                self.claims.release(&claim);
                return Err(refusal);
            }
        };
        let digest = sha256_hex(&manifest);

        // 3. The checkpoint of the record and Journal the proposal came from.
        let record_bytes = record
            .durable_bytes()
            .map_err(|error| storage(error.message))?;
        let last = last_sequence(&replayed);
        marker.insert(
            "checkpointSeal".into(),
            json!({"sha256": sha256_hex(&record_bytes),
                "byteCount": journal_bytes.len().to_string(), "lastSequence": last}),
        );
        marker.insert(
            "proposal".into(),
            json!({"manifestSHA256": digest, "manifestByteCount": manifest.len().to_string(),
                "terminalStatus": record.state, "outcomeCertainty": "confirmed",
                "completedAtUTC": completed}),
        );
        let job =
            HostDirectory::open(job_directory).map_err(|e| write_failed(job_directory, &e))?;
        job.publish_document(PROPOSAL, &manifest, MAXIMUM_MANIFEST)
            .map_err(|error| publish_failed(&job_directory.join(PROPOSAL), error))?;

        // 4. The Job's own Journal ends with `finalized`, which names the
        //    proposal; the Session's Journal seal binds the complete Journal.
        if !replay.finalized {
            let envelope = Envelope {
                event_id: "session-finalized".into(),
                sequence: last + 1,
                session_id: session_id.clone(),
                job_id: record.job_id.clone(),
                timestamp: now.into(),
            };
            journal
                .append(&events::finalized(
                    &envelope,
                    &record.state,
                    &digest,
                    "confirmed",
                ))
                .map_err(|error| storage(error.to_string()))?;
        }
        let sealed = std::fs::read(&journal_path).map_err(|e| write_failed(&journal_path, &e))?;
        let sealed_events = events_of(&sealed)?;

        // 5. The Session tree, created once.
        let session_path = root_path.join(&year).join(&month).join(&session_id);
        let year_root = root
            .private_child(&year)
            .map_err(|e| write_failed(&root_path.join(&year), &e))?;
        let month_root = year_root
            .private_child(&month)
            .map_err(|e| write_failed(&root_path.join(&year).join(&month), &e))?;
        let session = month_root
            .create_private_child(&session_id)
            .map_err(|error| {
                if error.kind() == io::ErrorKind::AlreadyExists {
                    storage(format!(
                        "invalidRecord(\"Session already exists: {session_id}\")"
                    ))
                } else {
                    write_failed(&session_path, &error)
                }
            })?;
        let child = |parent: &HostDirectory, name: &str, path: &Path| {
            parent
                .private_child(name)
                .map_err(|e| write_failed(&path.join(name), &e))
        };
        let audit = child(&session, "audit", &session_path)?;
        let artifacts = child(&session, "artifacts", &session_path)?;
        let artifacts_path = session_path.join("artifacts");
        let raw = child(&artifacts, "raw", &artifacts_path)?;
        let derived = child(&artifacts, "derived", &artifacts_path)?;
        let partial = child(&artifacts, "partial", &artifacts_path)?;
        let identity = crate::session_json::encode(&json!({"jobId": record.job_id,
            "schemaVersion": "1.0.0", "sessionId": session_id}))
        .map_err(|_| storage("invalidRecord(\"invalid Session identity file\")"))?;
        session
            .create_document(".session-identity.json", &identity)
            .map_err(|e| write_failed(&session_path.join(".session-identity.json"), &e))?;
        for directory in [
            &audit,
            &raw,
            &derived,
            &partial,
            &artifacts,
            &session,
            &month_root,
            &year_root,
            &root,
        ] {
            directory
                .sync()
                .map_err(|e| write_failed(&session_path, &e))?;
        }
        let bound = session
            .export_facts()
            .map_err(|e| write_failed(&session_path, &e))?;
        marker.insert(
            "sessionRootIdentity".into(),
            json!({"device": bound.device.to_string(), "inode": bound.inode.to_string()}),
        );
        marker.insert("phase".into(), json!("prepared"));

        // 6. The Session's Journal, byte for byte the Job's.
        {
            let mut copy = JournalWriter::open(&session_path, true)
                .map_err(|error| storage(error.to_string()))?;
            for event in &sealed_events {
                copy.append(event)
                    .map_err(|error| storage(error.to_string()))?;
            }
        }
        let copied = session
            .read("journal.jsonl", MAXIMUM_JOURNAL)
            .map_err(|e| write_failed(&session_path.join("journal.jsonl"), &e))?;
        if copied != sealed {
            return Err(stop(
                "sourceIntegrityFailed",
                "the Session Journal copy is not byte-identical to the Job Journal",
            ));
        }
        marker.insert(
            "journalSeal".into(),
            json!({"sha256": sha256_hex(&copied), "byteCount": copied.len().to_string(),
                "lastSequence": last_sequence(&sealed_events)}),
        );
        marker.insert("phase".into(), json!("sealed"));

        // 7. The outcome audit, then the write-once Manifest under the
        //    Session's terminal lock and every Artifact publication shard.
        let mut outcome = crate::session_json::encode(&json!({
            "auditId": format!("session-publication-{}", record.job_id), "category": "outcome",
            "correlationId": record.job_id,
            "details": {"manifestSha256": digest, "operation": record.operation(),
                "terminalStatus": record.state},
            "jobId": record.job_id, "recordId": "session-publication-outcome",
            "schemaVersion": "1.0.0", "sessionId": session_id, "timestamp": now}))
        .map_err(|_| storage("invalidRecord(\"Session audit record exceeds bound\")"))?;
        outcome.push(b'\n');
        audit
            .append_record("session.jsonl", &outcome)
            .map_err(|e| write_failed(&session_path.join("audit/session.jsonl"), &e))?;
        {
            let _terminal = session
                .wait_lock(".manifest.lock", true)
                .map_err(|e| write_failed(&session_path.join(".manifest.lock"), &e))?;
            let mut shards = Vec::with_capacity(SHARDS.len());
            for shard in SHARDS.chars() {
                let name = format!(".publication-lock-{shard}.lock");
                shards.push(
                    partial.wait_lock(&name, false).map_err(|e| {
                        write_failed(&artifacts_path.join("partial").join(&name), &e)
                    })?,
                );
            }
            session
                .publish_exclusive("manifest.json", &manifest)
                .map_err(|error| publish_failed(&session_path.join("manifest.json"), error))?;
            while let Some(shard) = shards.pop() {
                drop(shard);
            }
        }
        if session
            .read("manifest.json", MAXIMUM_MANIFEST)
            .ok()
            .as_deref()
            != Some(manifest.as_slice())
        {
            return Err(stop(
                "contractViolation",
                "published Manifest does not read back",
            ));
        }
        marker.insert("phase".into(), json!("manifestPublished"));

        // 8. The catalog's own entry, read back, is the receipt.
        let generation = self
            .sessions
            .register_published_session(&root_path, [&year, &month, &session_id])
            .map_err(storage)?;
        marker.insert(
            "receipt".into(),
            json!({"manifestSHA256": digest, "catalogGeneration": generation.to_string(),
                "publishedAtUTC": now}),
        );
        marker.insert("phase".into(), json!("catalogPublished"));
        self.claims.release(&claim);
        Ok(Value::Object(marker))
    }
}

/// Swift `refusedRecord`: an unbound marker carrying the confirmed reason.
fn refused(record: &JobRecord, stopped: &Stop) -> Value {
    json!({
        "sessionID": format!("session-{}", record.job_id),
        "catalogDigest": record.catalog_digest(), "policyGeneration": "0",
        "root": {"path": "", "device": "0", "inode": "0", "volumeIdentity": ""},
        "relativeSessionPath": "", "claims": [], "phase": "awaitingStorage",
        "failure": {"code": stopped.reason, "certainty": "confirmed",
            "detail": stopped.detail.chars().take(512).collect::<String>()},
    })
}

/// Swift `RuntimeSessionManifestComposer.compose`: this Job's canonical
/// Manifest, rendered only from its record and Journal, or the refusal
/// naming the fact it lacks.
fn compose(
    record: &JobRecord,
    events: &[Value],
    replay: &ReplayFacts,
    completed: &str,
) -> Result<Vec<u8>, Stop> {
    let status = record.state.as_str();
    if !["succeeded", "failed", "cancelled", "interrupted"].contains(&status) {
        return Err(stop(
            "contractViolation",
            format!("terminal state {status} has no current Manifest status"),
        ));
    }
    if record.outcome_unknown()
        || !replay.outstanding_intents.is_empty()
        || !replay.unknown_outcomes.is_empty()
    {
        return Err(stop(
            "contractViolation",
            "an unresolved Job cannot be sealed as a confirmed Session",
        ));
    }
    let created = events.first().filter(|event| event["kind"] == "jobCreated");
    let fact = |key: &str| created.and_then(|event| event["payload"][key].as_str());
    let (Some(mode), Some(authority), Some(baseline)) = (
        fact("executionMode"),
        fact("executionAuthority"),
        fact("coreBaseline"),
    ) else {
        return Err(stop(
            "sourceIntegrityFailed",
            "the Job Journal does not open with its own creation facts",
        ));
    };
    let steps = manifest_steps(events)?;
    let compensations = manifest_compensations(events)?;
    let device = device_context(record, events, mode)?;
    let mut bindings = manifest_bindings(events);
    if let Some(device) = &device
        && bindings.is_empty()
    {
        bindings = vec![device.binding.clone()];
    }
    let (target, toolchain) = match &device {
        Some(device) => (device.target.clone(), device.toolchain.clone()),
        // An honest host branch: no device is named, not even the target the
        // request carried.
        None if !touches_device(events) && bindings.is_empty() => (
            json!({"kind": "host", "connectKey": null, "transport": "host",
                "identitySnapshot": {"workspaceScope": record.request["target"]["targetId"],
                    "providerId": record.provider(), "catalogDigest": record.catalog_digest()}}),
            json!({"kind": "none"}),
        ),
        None => {
            return Err(stop(
                "sourceIntegrityFailed",
                "device-bound Session publication needs target and toolchain facts this Job \
                 record does not carry",
            ));
        }
    };
    let mut manifest = json!({
        "schemaVersion": "1.0.0", "appVersion": APP_VERSION, "coreSpecBaseline": baseline,
        "platformProfile": PLATFORM_PROFILE, "sessionId": format!("session-{}", record.job_id),
        "jobId": record.job_id, "status": status, "executionMode": mode,
        "executionAuthority": authority, "outcomeCertainty": "confirmed",
        "sessionDisposition": "finalized", "createdAt": record.created(),
        "completedAt": completed, "archivedAt": null,
        "originalTarget": target, "bindingHistory": bindings, "toolchain": toolchain,
        "workflow": {"kind": record.operation(), "profileVersion": record.catalog_digest(),
            "providerIdentity": record.provider()},
        "steps": steps, "parameters": [], "compensations": compensations,
        "confirmations": [],
        // Runtime Artifacts stay in the Artifact store; Swift copies none.
        "artifacts": [], "warnings": [], "recovery": null,
    });
    if let Some(device) = device {
        manifest["runtimeAuthority"] = device.authority;
    }
    manifest["failure"] = if status == "failed" {
        let Some(failure) = record.operation_failure() else {
            return Err(stop(
                "sourceIntegrityFailed",
                "a failed Job must carry its durable failure facts",
            ));
        };
        let text = |key: &str| failure[key].as_str().unwrap_or_default().to_owned();
        json!({"stage": "runtime", "code": text("code"),
            "summary": format!("{}/{}/{}", text("category"), text("retryability"), text("recovery"))})
    } else {
        Value::Null
    };
    let refused = |rule: Option<&str>| {
        stop(
            "contractViolation",
            match rule {
                Some(rule) => format!(
                    "composed Manifest was refused by the current contract: invalidManifest({})",
                    crate::artifact_read_owner::swift_string(rule)
                ),
                None => "composed Manifest was refused by the current contract".into(),
            },
        )
    };
    let bytes = crate::session_json::encode(&manifest).map_err(|_| refused(None))?;
    // Swift `SessionManifestDocument(data:)`: the locked contract and bound,
    // a rule it names refused under that name.
    if bytes.len() > MAXIMUM_MANIFEST {
        return Err(refused(None));
    }
    match crate::session_manifest::decode_manifest(&bytes) {
        Ok(_) => Ok(bytes),
        Err(crate::session_manifest::ManifestError::Rule(rule)) => Err(refused(Some(rule))),
        Err(_) => Err(refused(None)),
    }
}

/// Swift `manifestSteps`: each intent's typed declaration with the tuple its
/// correlated outcome proves; a retried Step keeps its latest row.
fn manifest_steps(events: &[Value]) -> Result<Vec<Value>, Stop> {
    let outcomes = correlated(events, "stepOutcome");
    let mut steps: Vec<Value> = Vec::new();
    let mut seen = BTreeSet::new();
    for event in events.iter().filter(|event| event["kind"] == "stepIntent") {
        let event_id = event["eventId"].as_str().unwrap_or_default();
        let (Some(step_id), Some(Value::Object(step))) =
            (event["stepId"].as_str(), event["payload"].get("step"))
        else {
            return Err(stop(
                "sourceIntegrityFailed",
                format!("Journal Step intent {event_id} carries no typed declaration"),
            ));
        };
        if !seen.insert(step_id) {
            steps.retain(|existing| existing["id"] != step_id);
        }
        let Some(hash) = event["argumentsHash"].as_str() else {
            return Err(stop(
                "sourceIntegrityFailed",
                format!("Journal Step intent {event_id} carries no arguments hash"),
            ));
        };
        let (disposition, certainty, result) =
            execution_tuple(outcomes.get(event_id).copied(), step_id)?;
        let mut row = step.clone();
        row.insert("argumentsHash".into(), json!(hash));
        row.insert("sourceStepId".into(), Value::Null);
        row.insert("compensationTrigger".into(), Value::Null);
        row.insert(
            "bindingRevision".into(),
            event["bindingRevision"]
                .as_i64()
                .map_or(Value::Null, |revision| json!(revision)),
        );
        row.insert("disposition".into(), json!(disposition));
        row.insert("outcomeCertainty".into(), json!(certainty));
        row.insert("semanticResult".into(), json!(result));
        steps.push(Value::Object(row));
    }
    Ok(steps)
}

/// Swift `manifestCompensations`.
fn manifest_compensations(events: &[Value]) -> Result<Vec<Value>, Stop> {
    let outcomes = correlated(events, "compensationOutcome");
    let mut records: Vec<Value> = Vec::new();
    for event in events
        .iter()
        .filter(|event| event["kind"] == "compensationIntent")
    {
        let event_id = event["eventId"].as_str().unwrap_or_default();
        let (Some(descriptor_id), Some(descriptor), Some(source)) = (
            event["stepId"].as_str(),
            event["payload"].get("descriptor"),
            event["payload"]["compensationOfStepId"].as_str(),
        ) else {
            return Err(stop(
                "sourceIntegrityFailed",
                format!("Journal compensation intent {event_id} is incomplete"),
            ));
        };
        let outcome = outcomes.get(event_id).copied();
        let (disposition, certainty, result) = execution_tuple(outcome, descriptor_id)?;
        let mut identities = vec![json!(event_id)];
        if let Some(outcome) = outcome {
            identities.push(outcome["eventId"].clone());
        }
        let failure = if result == "failed" {
            json!({"stage": "compensation", "code": "compensation.failed",
                "summary": outcome.and_then(|outcome| outcome["payload"]["summary"].as_str())
                    .unwrap_or("compensation reported failure")})
        } else {
            Value::Null
        };
        records.retain(|existing| existing["descriptor"]["id"] != descriptor_id);
        records.push(json!({"descriptor": descriptor, "sourceStepId": source,
            "disposition": disposition, "outcomeCertainty": certainty, "result": result,
            "failure": failure, "journalEventIds": identities}));
    }
    Ok(records)
}

/// Each outcome of `kind` by the intent it correlates to.
fn correlated<'a>(events: &'a [Value], kind: &str) -> BTreeMap<&'a str, &'a Value> {
    events
        .iter()
        .filter(|event| event["kind"] == kind)
        .filter_map(|event| {
            Some((
                event["payload"]["correlatesToIntentEventId"].as_str()?,
                event,
            ))
        })
        .collect()
}

/// Swift `executionTuple`: derived only from a recorded outcome; a Step with
/// no outcome did not execute.
fn execution_tuple(
    outcome: Option<&Value>,
    context: &str,
) -> Result<(&'static str, &'static str, &'static str), Stop> {
    let Some(outcome) = outcome else {
        return Ok(("skipped", "notApplicable", "notRun"));
    };
    let (Some(result), Some(certainty)) = (
        outcome["payload"]["result"].as_str(),
        outcome["payload"]["outcomeCertainty"].as_str(),
    ) else {
        return Err(stop(
            "sourceIntegrityFailed",
            format!("Journal outcome for {context} is incomplete"),
        ));
    };
    if certainty != "confirmed" {
        return Ok(("outcomeUnknown", "outcomeUnknown", "unknown"));
    }
    Ok((
        "executed",
        "confirmed",
        if result == "succeeded" {
            "succeeded"
        } else {
            "failed"
        },
    ))
}

/// Swift `manifestBindings`: the Journal's confirmed bindings by revision.
fn manifest_bindings(events: &[Value]) -> Vec<Value> {
    let mut by_revision = BTreeMap::new();
    for event in events
        .iter()
        .filter(|event| event["kind"] == "bindingConfirmed")
    {
        let (Some(revision), Some(binding)) = (
            event["bindingRevision"].as_i64(),
            event["payload"]["binding"].as_object(),
        ) else {
            continue;
        };
        let mut entry = binding.clone();
        entry.insert("revision".into(), json!(revision));
        by_revision.insert(revision, Value::Object(entry));
    }
    by_revision.into_values().collect()
}

/// Swift `DeviceContext`: the audit projection of device facts this Job
/// already owns.
struct DeviceContext {
    target: Value,
    binding: Value,
    toolchain: Value,
    authority: Value,
}

fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Swift `deviceContext`: a Job whose Journal holds an intent that can touch
/// a device becomes a device Session only through its own verified
/// observation, Journal device outcomes that are confirmed and agree with it,
/// and its admission audit. None when no intent can touch a device.
fn device_context(
    record: &JobRecord,
    events: &[Value],
    mode: &str,
) -> Result<Option<DeviceContext>, Stop> {
    fn declaration(event: &Value) -> Option<&Value> {
        let key = match event["kind"].as_str() {
            Some("stepIntent") => "step",
            Some("compensationIntent") => "descriptor",
            _ => return None,
        };
        Some(&event["payload"][key]).filter(|step| step.is_object())
    }
    let intents: Vec<&Value> = events
        .iter()
        .filter(|event| {
            declaration(event).is_some_and(|step| {
                step["effect"].as_str() != Some("hostOnly")
                    || step["bindingRequirement"].as_str() != Some("none")
            })
        })
        .collect();
    if intents.is_empty() {
        return Ok(None);
    }
    let refused = |detail: &str| stop("sourceIntegrityFailed", format!("device Session: {detail}"));
    let inconsistent = || refused("missing or inconsistent job-local target/tool observation");
    let requested = &record.request["target"];
    let observed = record.evidence_observation().filter(|_| mode == "execute");
    let text = |key: &str| observed.and_then(|observation| observation[key].as_str());
    let seconds = |at: Option<&str>| at.and_then(crate::format_time::format_timestamp_seconds);
    let target_id = text("targetID")
        .filter(|target| Some(*target) == requested["targetId"].as_str())
        .ok_or_else(inconsistent)?;
    let revision = observed
        .and_then(|observation| observation["bindingRevision"].as_i64())
        .filter(|revision| {
            *revision > 0
                && Some(*revision) == requested["expectedBindingRevision"].as_i64()
                && record
                    .materialized_binding()
                    .is_none_or(|bound| bound == *revision)
        })
        .ok_or_else(inconsistent)?;
    let identity = text("stableIdentitySHA256")
        .filter(|identity| {
            lowercase_sha256(identity)
                && record
                    .materialized_identity()
                    .is_none_or(|bound| bound == *identity)
        })
        .ok_or_else(inconsistent)?;
    let provider = text("providerID")
        .filter(|provider| *provider == record.provider() && ["hdc", "arkforge"].contains(provider))
        .ok_or_else(inconsistent)?;
    let model = text("model")
        .filter(|model| !model.is_empty())
        .ok_or_else(inconsistent)?;
    let firmware = text("firmware")
        .filter(|firmware| !firmware.is_empty())
        .ok_or_else(inconsistent)?;
    let transport = text("transport")
        .filter(|transport| ["usb", "tcp", "uart"].contains(transport))
        .ok_or_else(inconsistent)?;
    let confirmed = text("confirmedAtUTC").ok_or_else(inconsistent)?;
    let tool_version = text("toolVersion")
        .filter(|version| !version.is_empty())
        .ok_or_else(inconsistent)?;
    let tool_sha256 = text("toolSHA256")
        .filter(|digest| lowercase_sha256(digest))
        .ok_or_else(inconsistent)?;
    let (Some(confirmed_at), Some(started_at), Some(finished_at)) = (
        seconds(Some(confirmed)),
        seconds(Some(record.created())),
        seconds(record.finished_at()),
    ) else {
        return Err(inconsistent());
    };
    if text("confirmationMethod") != Some("machineReadback")
        || started_at > confirmed_at
        || confirmed_at > finished_at
    {
        return Err(inconsistent());
    }

    let mut connect_key: Option<&str> = None;
    let mut confirmed_outcome = false;
    let mut mutation = false;
    for intent in intents {
        let target = &intent["payload"]["target"];
        let key = target["connectKey"].as_str().filter(|key| !key.is_empty());
        let agrees = intent["bindingRevision"].as_i64() == Some(revision)
            && target["scope"] == "device"
            && target["targetId"] == target_id
            && target["identitySnapshotHash"] == identity
            && key.is_some()
            && connect_key.is_none_or(|known| Some(known) == key);
        if !agrees {
            return Err(refused(
                "Journal target or binding differs from the verified observation",
            ));
        }
        connect_key = key;
        let outcome = events
            .iter()
            .filter(|event| {
                matches!(
                    event["kind"].as_str(),
                    Some("stepOutcome" | "compensationOutcome")
                )
            })
            .find(|event| {
                event["payload"]["correlatesToIntentEventId"].as_str() == intent["eventId"].as_str()
            })
            .filter(|outcome| outcome["payload"]["outcomeCertainty"] == "confirmed")
            .ok_or_else(|| refused("Journal device outcome is missing or not confirmed"))?;
        confirmed_outcome |= outcome["payload"]["result"] == "succeeded";
        mutation |= declaration(intent).is_some_and(|step| {
            matches!(
                step["effect"].as_str(),
                Some("deviceMutation" | "destructive")
            )
        });
    }
    let (Some(connect_key), true) = (connect_key, confirmed_outcome) else {
        return Err(refused(
            "no confirmed device outcome substantiates the target",
        ));
    };
    let unaudited = || refused("missing admission audit or unsupported recovery provenance");
    let admission = record.admission().ok_or_else(unaudited)?;
    let member = |key: &str| admission.get(key).cloned().unwrap_or(Value::Null);
    let admitted = seconds(admission["admittedAtUTC"].as_str());
    if !admission["reference"]
        .as_str()
        .is_some_and(|reference| !reference.is_empty())
        || !admitted.is_some_and(|admitted| admitted <= confirmed_at)
        || !member("completeOverwriteRecovery").is_null()
    {
        return Err(unaudited());
    }
    let mut authority = json!({
        "kind": member("kind"), "reference": member("reference"),
        "admittedAtUtc": member("admittedAtUTC"), "validUntilUtc": member("validUntilUTC"),
        "consumptionFingerprintSha256": member("consumptionFingerprintSHA256"),
        "reservationId": null, "useOrdinal": null, "planDigest": null,
        "stepSetDigest": null, "targetBindingDigest": null, "artifactDigest": null,
    });
    match admission["kind"].as_str() {
        Some("defaultReadOnlyPolicy") => {
            if mutation
                || !member("validUntilUTC").is_null()
                || !member("consumptionFingerprintSHA256").is_null()
                || !member("runtimeCapabilityCorrelation").is_null()
            {
                return Err(refused("read-only policy cannot substantiate a mutation"));
            }
        }
        Some("runtimeCapability") => {
            let correlation = &admission["runtimeCapabilityCorrelation"];
            if !correlation["reservationID"]
                .as_str()
                .is_some_and(|s| !s.is_empty())
                || !correlation["useOrdinal"].as_u64().is_some_and(|n| n > 0)
                || !admission["consumptionFingerprintSHA256"]
                    .as_str()
                    .is_some_and(lowercase_sha256)
                || !seconds(admission["validUntilUTC"].as_str())
                    .zip(admitted)
                    .is_some_and(|(expiry, start)| start < expiry)
                || correlation["planDigestSHA256"].as_str() != record.materialized_plan()
                || ![
                    "planDigestSHA256",
                    "stepSetDigestSHA256",
                    "targetBindingDigestSHA256",
                ]
                .iter()
                .all(|key| correlation[*key].as_str().is_some_and(lowercase_sha256))
                || (!correlation["artifactSHA256"].is_null()
                    && !correlation["artifactSHA256"]
                        .as_str()
                        .is_some_and(lowercase_sha256))
            {
                return Err(refused(
                    "missing or inconsistent consumed Runtime capability audit",
                ));
            }
            for (destination, source) in [
                ("reservationId", "reservationID"),
                ("useOrdinal", "useOrdinal"),
                ("planDigest", "planDigestSHA256"),
                ("stepSetDigest", "stepSetDigestSHA256"),
                ("targetBindingDigest", "targetBindingDigestSHA256"),
                ("artifactDigest", "artifactSHA256"),
            ] {
                authority[destination] = correlation[source].clone();
            }
        }
        _ => {
            return Err(refused(
                "missing or inconsistent consumed Runtime capability audit",
            ));
        }
    }
    let snapshot = json!({"targetId": target_id, "stableIdentitySHA256": identity,
        "model": model, "firmware": firmware});
    Ok(Some(DeviceContext {
        target: json!({"kind": "real", "connectKey": connect_key, "transport": transport,
            "identitySnapshot": snapshot}),
        binding: json!({
            "revision": revision, "connectKey": connect_key, "transport": transport,
            "identitySnapshot": snapshot,
            "evidence": [
                format!("Job-local machine readback at {confirmed}"),
                format!("Confirmed Journal device outcomes at binding revision {revision}"),
            ],
            "confirmedBy": "corePolicy", "channelProtection": "unverifiedAssumeUnprotected",
        }),
        toolchain: json!({"kind": "runtimeProvider", "providerIdentity": provider,
            "profileIdentifier": record.operation(), "reportedVersion": tool_version,
            "sha256": tool_sha256}),
        authority,
    }))
}

/// Whether any intent can touch a device, which is what makes Swift build a
/// device Session.
fn touches_device(events: &[Value]) -> bool {
    events.iter().any(|event| {
        let declaration = match event["kind"].as_str() {
            Some("stepIntent") => &event["payload"]["step"],
            Some("compensationIntent") => &event["payload"]["descriptor"],
            _ => return false,
        };
        declaration.is_object()
            && (declaration["effect"].as_str() != Some("hostOnly")
                || declaration["bindingRequirement"].as_str() != Some("none"))
    })
}

/// Every record of a Journal whose tail is whole.
fn events_of(bytes: &[u8]) -> Result<Vec<Value>, Stop> {
    let unreadable = || storage("sequenceViolation(\"the Job Journal cannot be replayed\")");
    bytes
        .strip_suffix(b"\n")
        .ok_or_else(unreadable)?
        .split(|byte| *byte == b'\n')
        .map(|line| serde_json::from_slice(line).map_err(|_| unreadable()))
        .collect()
}

fn last_sequence(events: &[Value]) -> i64 {
    events
        .last()
        .and_then(|event| event["sequence"].as_i64())
        .unwrap_or(-1)
}

/// The UTC `yyyy` and `mm` of an ISO 8601 time: Swift's Session partition.
fn utc_month(at: &str) -> Option<(String, String)> {
    let text = host_gregorian_timestamp(crate::session_time::session_timestamp(at)?)?;
    Some((text.get(..4)?.to_owned(), text.get(5..7)?.to_owned()))
}

/// Foundation `URL.resolvingSymlinksInPath()` of an already canonical path:
/// a `/private` prefix is dropped when the remainder names the same
/// directory, as `/tmp` and `/var` do.
fn foundation_path(path: &Path) -> String {
    let text = path.to_string_lossy();
    if let Some(rest) = text.strip_prefix("/private/") {
        let stripped = format!("/{rest}");
        if let (Ok(short), Ok(long)) = (std::fs::metadata(&stripped), std::fs::metadata(path))
            && short.dev() == long.dev()
            && short.ino() == long.ino()
        {
            return stripped;
        }
    }
    text.into_owned()
}

/// Swift `UUID().uuidString`: a random version 4 identity in upper case.
fn uuid() -> io::Result<String> {
    let mut bytes = arkdeck_platform::random_bytes::<16>()?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02X}")).collect();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}
