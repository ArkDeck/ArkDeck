//! Swift `RuntimeJobResourceReader` for `job.result` and `job.evidence`, over
//! the Job and Artifact owners the isolated Rust composition opened: the Job
//! read from its durable index, its declared products verified byte for byte,
//! the evidence and inventory rendered as Swift renders them, and the cleanup
//! ledger's outstanding rows. Reads write nothing; Swift's reader may create a
//! Job's empty Artifact directory, reseal a payload or refresh its
//! verification cache while it reads.
//!
//! Only Jobs of the operations this Runtime runs are read. An unreadable
//! recovery-epoch store, or an epoch naming the Job as the Job that recovered
//! (a `recoveryEpoch` the published schema still pins to null), degrades the
//! evidence. A product the request chose not to take may stay missing; any
//! other missing product fails the evidence.
use crate::artifact_read_owner::ArtifactReadStore;
use crate::artifact_usage::decode_index;
use crate::device_steps;
use crate::job_owner::JobStore;
use crate::job_record::{JobRecord, terminal};
use crate::operation_catalog::CatalogOperation;
use arkdeck_contract::{CATALOG_DIGEST, WireError, canonical_json, sha256_hex};
use arkdeck_platform::PayloadCheck;
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;

/// The operations whose results this Runtime reads.
const READABLE: [&str; 12] = [
    "analyzer.extract-crash-signature@1",
    "observe.device@1",
    "debug.template@1",
    "capture.diagnostics@1",
    "input.tap@1",
    "input.long-press@1",
    "input.swipe@1",
    "port-forward.create@1",
    "port-forward.remove@1",
    "debug.hap@1",
    "capture.screen-sequence@1",
    "deploy.native-library.app-owned@1",
];
const MAX_LEDGER: usize = 16 * 1024 * 1024;
/// Swift `RuntimeJobReadProjection.bounded`.
const MAX_RESPONSE: usize = 4 * 1024 * 1024;

fn proven(code: &str, message: impl Into<String>, mut details: Map<String, Value>) -> WireError {
    details.insert("phase".into(), json!("preAdmission"));
    details.insert("newDispatchCount".into(), json!(0));
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(details),
    }
}

fn bare(code: &str, message: impl Into<String>) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: None,
    }
}

/// Swift `AgentExecutionIntent.validIdentifier`.
fn valid_identifier(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.as_bytes()[0].is_ascii_alphanumeric()
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

/// Swift `RuntimeArtifactStore.directory(for:)`: letters, digits, `-`, `_`.
fn artifact_job(id: &str) -> bool {
    id.bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte))
}

pub struct JobResultReader<'a> {
    pub jobs: &'a JobStore,
    pub artifacts: &'a ArtifactReadStore,
}

/// What `RuntimeJobResourceReader.evidenceFacts` derives once for both reads.
struct Facts {
    blockers: BTreeSet<&'static str>,
    metadata: Vec<Value>,
    verified: Vec<Value>,
    inventory_available: bool,
    missing: Vec<String>,
    degraded: bool,
}

impl JobResultReader<'_> {
    /// The evidence Swift `executionResultProjection` attaches to a terminal
    /// Job: the same facts and blockers `job.evidence` reads, encoded as
    /// `AgentDaemon.encodeEvidence` encodes them — each verified Artifact's
    /// byte count a number — without the inputs or Trace probes, and
    /// `verified`, or `blocked` when a blocker stands.
    pub(crate) fn agent_evidence(&self, record: &JobRecord) -> Value {
        let facts = self.facts(record, true);
        let mut fields = record.evidence_fields();
        if let Some(kinds) = self.durable_step_kinds(record) {
            fields.insert("actualStepKinds".into(), kinds);
        }
        for key in ["parameters", "traceProbeBefore", "traceProbeAfter"] {
            fields.remove(key);
        }
        let artifacts: Vec<Value> = facts
            .verified
            .iter()
            .map(|row| {
                let mut row = row.clone();
                if let Some(count) = row["byteCount"]
                    .as_str()
                    .and_then(|text| text.parse::<u64>().ok())
                {
                    row["byteCount"] = json!(count);
                }
                row
            })
            .collect();
        let blockers: Vec<&str> = facts.blockers.iter().copied().collect();
        fields.insert(
            "status".into(),
            json!(if blockers.is_empty() {
                "verified"
            } else {
                "blocked"
            }),
        );
        fields.insert("artifacts".into(), json!(artifacts));
        fields.insert("blockers".into(), json!(blockers));
        Value::Object(fields)
    }

    pub fn handle(&self, method: &str, params: &Map<String, Value>) -> Result<Value, WireError> {
        let id = match (params.len(), params.get("jobId").and_then(Value::as_str)) {
            (1, Some(id)) if valid_identifier(id) => id,
            _ => {
                return Err(proven(
                    "invalidInput",
                    "an exact Job identity and closed read options are required",
                    Map::new(),
                ));
            }
        };
        let record = self.snapshot(id)?;
        if !READABLE.contains(&record.operation()) {
            return Err(proven(
                "rejected",
                format!(
                    "the Rust Runtime does not read the result of {} Jobs yet",
                    record.operation()
                ),
                Map::new(),
            ));
        }
        let status = record.status();
        let is_terminal = terminal(&record.state);
        if method == "job.result" && !is_terminal {
            return Err(proven(
                "resultNotReady",
                "the Job has no terminal result yet",
                Map::from_iter([
                    ("jobId".into(), json!(id)),
                    ("state".into(), json!(record.state)),
                    ("nextAction".into(), status["nextAction"].clone()),
                ]),
            ));
        }
        let facts = self.facts(&record, is_terminal);
        let (mut evidence, inventory) = render(&record, &facts, is_terminal);
        if let Some(kinds) = self.durable_step_kinds(&record).filter(|_| !facts.degraded) {
            evidence["actualStepKinds"] = kinds;
        }
        let result = if method == "job.evidence" {
            evidence
        } else {
            let cleanup = self.cleanup(id)?;
            let mut job = status;
            job["outstandingResidueCount"] = json!(cleanup.len());
            let next = if record.outcome_unknown() {
                job["nextAction"].clone()
            } else if let Some(first) = cleanup.first() {
                json!({"kind": "cleanup", "owner": {"kind": "job", "id": id},
                    "resource": {"kind": "cleanupDebt", "id": first["cleanupDebtId"]},
                    "reasonCode": "recovery.cleanupDebt"})
            } else {
                Value::Null
            };
            json!({"schemaVersion": "arkdeck.job-result/1", "job": job, "terminal": is_terminal,
                "outcomeUnknown": record.outcome_unknown(), "evidence": evidence,
                "artifacts": inventory, "cleanup": cleanup, "nextAction": next})
        };
        // A read cannot attach facts from a newer Job snapshot to an older one.
        let current = self.snapshot(id)?;
        if current.value().ok() != record.value().ok() {
            return Err(proven(
                "resourceConflict",
                "the Job changed while its evidence was being read",
                Map::new(),
            ));
        }
        let size = canonical_json(&result)
            .map_err(|_| bare("recordUnreadable", "the Job read resource is unreadable"))?
            .len();
        if size > MAX_RESPONSE {
            return Err(proven(
                "inputTooLarge",
                "Job read projection exceeds its bounded response size",
                Map::new(),
            ));
        }
        Ok(result)
    }

    /// Swift `durableActualStepKinds` for a debug HAP: the kinds its record
    /// kept, then any its journal's step and compensation intents prove, in
    /// journal order, so a record persisted before its last intents loses
    /// none; `null` when the journal cannot be replayed. Every other Job
    /// reads the kinds its record kept.
    fn durable_step_kinds(&self, record: &JobRecord) -> Option<Value> {
        if record.operation() != "debug.hap@1" {
            return None;
        }
        let proven = self
            .jobs
            .journal_bytes(&record.job_id)
            .ok()
            .and_then(|bytes| intent_kinds(&bytes));
        Some(proven.map_or(Value::Null, |proven| {
            let mut kinds = record.step_kinds().unwrap_or_default().to_vec();
            for kind in proven {
                if !kinds.contains(&kind) {
                    kinds.push(kind);
                }
            }
            json!(kinds)
        }))
    }

    /// Swift `jobReadSnapshot` from the durable index, with its refusals.
    fn snapshot(&self, id: &str) -> Result<JobRecord, WireError> {
        self.jobs.read_snapshot(id)
    }

    fn facts(&self, record: &JobRecord, is_terminal: bool) -> Facts {
        let mut blockers = BTreeSet::new();
        let descriptor = (record.catalog_digest() == CATALOG_DIGEST)
            .then(|| {
                let (id, version) = record.operation().rsplit_once('@')?;
                CatalogOperation::lookup(id, version.parse().ok())
            })
            .flatten();
        if descriptor.is_none() {
            blockers.insert("operationUnavailable");
        }
        // Swift reads what the request left out from the persisted operation,
        // whichever catalog admitted it.
        let empty = Map::new();
        let inputs = record.request["inputs"].as_object().unwrap_or(&empty);
        let omitted = match record
            .operation()
            .rsplit_once('@')
            .and_then(|(id, version)| CatalogOperation::lookup(id, version.parse().ok()))
        {
            Some(operation) => device_steps::omitted_products(operation, inputs),
            None => {
                blockers.insert("recordUnreadable");
                BTreeSet::new()
            }
        };
        let (mut metadata, mut verified, mut inventory_available) = (Vec::new(), Vec::new(), false);
        let job_id = &record.job_id;
        match self.inventory(job_id, &omitted) {
            Ok((rows, integrity_failed)) => {
                metadata = rows;
                inventory_available = true;
                let owned = metadata.iter().all(|row| {
                    let binding = &row["bindingSnapshot"];
                    row["jobID"] == job_id.as_str()
                        && row["providerID"] == record.provider()
                        && row["sourceOperation"] == record.operation()
                        && binding["targetID"] == record.request["target"]["targetId"]
                        && record
                            .materialized_binding()
                            .is_none_or(|revision| binding["bindingRevision"] == revision)
                        && record
                            .materialized_identity()
                            .is_none_or(|identity| binding["stableIdentitySHA256"] == identity)
                });
                if !owned || integrity_failed.is_err() {
                    blockers.insert("artifactIntegrityFailed");
                } else if let Ok(rows) = integrity_failed {
                    verified = rows;
                }
            }
            Err(()) => {
                blockers.insert("artifactIntegrityFailed");
            }
        }
        let present: BTreeSet<&str> = metadata
            .iter()
            .filter_map(|row| row["name"].as_str())
            .collect();
        let missing: Vec<String> = descriptor
            .map(|operation| {
                operation
                    .artifacts
                    .iter()
                    .filter(|artifact| {
                        artifact.required
                            && !omitted.contains(&artifact.name)
                            && !present.contains(artifact.name.as_str())
                    })
                    .map(|artifact| artifact.name.clone())
                    .collect::<BTreeSet<_>>()
                    .into_iter()
                    .collect()
            })
            .unwrap_or_default();
        if !missing.is_empty() {
            blockers.insert("artifactIntegrityFailed");
        }
        if !is_terminal {
            blockers.insert("resultNotReady");
        }
        // Swift reads the recovery epochs for every snapshot and fails the
        // read when they are unreadable. An epoch that names this Job as the
        // Job that recovered is a `recoveryEpoch` the published evidence
        // schema still pins to null, so that evidence degrades as well.
        let degraded = self.jobs.recovery_epoch_names(job_id).unwrap_or(true);
        if degraded {
            blockers.insert("recordUnreadable");
        }
        let declares_nothing = descriptor.is_some_and(|operation| operation.artifacts.is_empty());
        Facts {
            blockers,
            metadata,
            verified: if degraded { Vec::new() } else { verified },
            inventory_available: inventory_available || declares_nothing,
            missing,
            degraded,
        }
    }

    /// Swift `evidenceInventory`: every index row in file order and, all or
    /// nothing, each published payload's full digest; a product the request
    /// intentionally omitted may be missing. The outer error is an unreadable
    /// index; the inner one an integrity failure.
    #[allow(clippy::type_complexity)]
    fn inventory(
        &self,
        job_id: &str,
        omitted: &BTreeSet<String>,
    ) -> Result<(Vec<Value>, Result<Vec<Value>, ()>), ()> {
        if !artifact_job(job_id) {
            return Err(());
        }
        let (job, bytes, _) = match self.artifacts.index(job_id) {
            Ok(found) => found,
            // Swift creates a Job's Artifact directory while it reads, so an
            // absent one reads as an empty index.
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok((Vec::new(), Ok(Vec::new())));
            }
            Err(_) => return Err(()),
        };
        if bytes.is_empty() {
            return Ok((Vec::new(), Ok(Vec::new())));
        }
        let rows = decode_index(&bytes, job_id).map_err(|_| ())?;
        if rows.is_empty() {
            return Ok((Vec::new(), Ok(Vec::new())));
        }
        let mut verified = Vec::new();
        for row in &rows {
            if row["status"].get("published").is_none() {
                let omission = row["status"].get("missing").is_some()
                    && row["name"]
                        .as_str()
                        .is_some_and(|name| omitted.contains(name));
                if omission {
                    continue;
                }
                // A missing or truncated product the request did not omit.
                return Ok((rows.clone(), Err(())));
            }
            let (Some(artifact), Some(length), Some(digest)) = (
                row["artifactID"].as_str(),
                row["byteCount"].as_u64(),
                row["sha256"].as_str(),
            ) else {
                return Ok((rows.clone(), Err(())));
            };
            if job.check_payload(artifact, length, digest).ok() != Some(PayloadCheck::Verified) {
                return Ok((rows.clone(), Err(())));
            }
            verified.push(json!({
                "reference": format!("arkdeck-artifact://{job_id}/{artifact}"),
                "sha256": digest,
                "jobId": row["jobID"],
                "targetId": row["bindingSnapshot"]["targetID"],
                "bindingRevision": row["bindingSnapshot"].get("bindingRevision").cloned().unwrap_or(Value::Null),
                "stableIdentitySha256": row["bindingSnapshot"].get("stableIdentitySHA256").cloned().unwrap_or(Value::Null),
                "providerId": row["providerID"],
                "byteCount": length.to_string(),
                "bytesVerified": true,
            }));
        }
        if verified.is_empty() {
            return Ok((rows, Err(())));
        }
        Ok((rows, Ok(verified)))
    }

    /// Complete outstanding cleanup census, including rows whose Job no longer
    /// appears in the index. Unreadable ledgers fail closed.
    pub fn outstanding_cleanup_debt(&self) -> Result<Vec<Value>, WireError> {
        let unreadable = || {
            proven(
                "recordUnreadable",
                "the Job cleanup ledger is unreadable",
                Map::new(),
            )
        };
        let bytes = match self.artifacts.root().read("cleanup-debt.json", MAX_LEDGER) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(_) => return Err(unreadable()),
        };
        let records: Vec<Value> = serde_json::from_slice(&bytes).map_err(|_| unreadable())?;
        let text =
            |record: &Value, key: &str| record.get(key).and_then(Value::as_str).map(str::to_owned);
        let mut outstanding = Vec::new();
        for record in &records {
            let (Some(job), Some(step), Some(remote), Some(_), Some(recorded)) = (
                text(record, "jobID"),
                text(record, "stepID"),
                text(record, "remotePath"),
                text(record, "reason"),
                text(record, "recordedAtUTC"),
            ) else {
                return Err(unreadable());
            };
            if record
                .get("settledAtUTC")
                .is_some_and(|value| !value.is_null())
            {
                continue;
            }
            let identity = match text(record, "bundleName") {
                Some(bundle) => format!("bundle:{bundle}"),
                None => remote.clone(),
            };
            let started = record
                .get("retryAttemptStartedAtUTC")
                .is_some_and(|value| !value.is_null());
            outstanding.push((
                job,
                remote,
                recorded,
                step,
                identity,
                record["retryOutcomeUnknown"] == true || started,
            ));
        }
        outstanding.sort_by(|left, right| {
            (&left.0, &left.1, &left.2).cmp(&(&right.0, &right.1, &right.2))
        });
        outstanding
            .into_iter()
            .map(|(job, _, recorded, step, identity, unknown)| {
                let hashed = canonical_json(&json!({"identity": identity, "jobId": job, "recordedAtUtc": recorded}))
                    .map_err(|_| unreadable())?;
                Ok(json!({"cleanupDebtId": format!("cleanup-{}", sha256_hex(&hashed)), "jobId": job,
                    "stepId": step, "recordedAtUtc": recorded, "outcomeUnknown": unknown}))
            })
            .collect()
    }
    /// Swift `listCleanupDebt` projection for one Job.
    fn cleanup(&self, job_id: &str) -> Result<Vec<Value>, WireError> {
        Ok(self
            .outstanding_cleanup_debt()?
            .into_iter()
            .filter(|row| row["jobId"].as_str() == Some(job_id))
            .collect())
    }
}

/// The kind of every step and compensation intent a journal's complete
/// records hold, in order, once they replay (Swift
/// `DurableJournalRecovery.inspect`); a torn tail is not read.
fn intent_kinds(bytes: &[u8]) -> Option<Vec<String>> {
    let replay = crate::job_journal_replay::ReplayState::replay(bytes).ok()?;
    let mut kinds = Vec::new();
    for line in bytes[..replay.durable_length]
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
    {
        let event: Value = serde_json::from_slice(line).ok()?;
        let key = match event["kind"].as_str() {
            Some("stepIntent") => "step",
            Some("compensationIntent") => "descriptor",
            _ => continue,
        };
        if let Some(kind) = event["payload"][key]["kind"].as_str() {
            kinds.push(kind.to_owned());
        }
    }
    Some(kinds)
}

/// Swift `RuntimeJobResourceReader.evidence`: the evidence object and the
/// result's Artifact inventory.
fn render(record: &JobRecord, facts: &Facts, is_terminal: bool) -> (Value, Vec<Value>) {
    let blockers: Vec<&str> = facts.blockers.iter().copied().collect();
    let status = if !is_terminal {
        "resultNotReady"
    } else if facts.blockers.contains("recordUnreadable") {
        "recordUnreadable"
    } else if facts.blockers.contains("artifactIntegrityFailed") {
        "artifactIntegrityFailed"
    } else if facts.blockers.contains("operationUnavailable") {
        "operationUnavailable"
    } else {
        "verified"
    };
    let mut fields = if facts.degraded {
        let mut fields = Map::from_iter([
            ("jobId".into(), json!(record.job_id)),
            ("operationReference".into(), json!(record.operation())),
            ("catalogDigest".into(), json!(record.catalog_digest())),
            (
                "targetId".into(),
                record.request["target"]["targetId"].clone(),
            ),
            ("providerId".into(), json!(record.provider())),
            ("executionMode".into(), json!("execute")),
            (
                "terminalState".into(),
                json!(if record.outcome_unknown() {
                    "outcomeUnknown"
                } else {
                    &record.state
                }),
            ),
            ("outcomeUnknown".into(), json!(record.outcome_unknown())),
            ("artifacts".into(), json!([])),
        ]);
        for name in [
            "bindingRevision",
            "actualEffect",
            "authority",
            "observation",
            "actualStepKinds",
            "startedAtUtc",
            "firstEvidenceStepAtUtc",
            "finishedAtUtc",
            "recoveryEpoch",
            "parameters",
            "traceProbeBefore",
            "traceProbeAfter",
        ] {
            fields.insert(name.into(), Value::Null);
        }
        fields
    } else {
        let mut fields = record.evidence_fields();
        fields.insert("artifacts".into(), json!(facts.verified));
        fields
    };
    fields.insert("blockers".into(), json!(blockers));
    fields.insert("schemaVersion".into(), json!("arkdeck.job-evidence/1"));
    fields.insert("status".into(), json!(status));
    fields.insert(
        "inventoryAvailable".into(),
        json!(facts.inventory_available),
    );
    fields.insert("missingRequiredArtifacts".into(), json!(facts.missing));
    let verified: BTreeSet<&str> = facts
        .verified
        .iter()
        .filter_map(|row| row["reference"].as_str())
        .collect();
    let mut rows: Vec<&Value> = facts.metadata.iter().collect();
    rows.sort_by(|left, right| {
        (left["name"].as_str(), left["artifactID"].as_str())
            .cmp(&(right["name"].as_str(), right["artifactID"].as_str()))
    });
    let inventory = rows
        .into_iter()
        .map(|row| {
            let artifact = row["artifactID"].as_str().unwrap_or_default();
            let reference = format!("arkdeck-artifact://{}/{artifact}", record.job_id);
            let state = ["published", "missing", "truncated"]
                .into_iter()
                .find(|state| row["status"].get(*state).is_some())
                .unwrap_or("published");
            json!({"artifactId": artifact, "owner": {"kind": "job", "id": record.job_id},
                "reference": reference, "name": row["name"], "mediaType": row["mediaType"],
                "byteCount": row["byteCount"].as_u64().unwrap_or(0).to_string(),
                "sha256": row["sha256"], "privacy": row["privacy"], "status": state,
                "bytesVerified": verified.contains(reference.as_str())})
        })
        .collect();
    (Value::Object(fields), inventory)
}
