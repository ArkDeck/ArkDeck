//! Swift `RuntimeArtifactStore`'s cleanup debt ledger as a device run writes
//! it: `cleanup-debt.json` in the Artifact root, an array of records in the
//! order they were owed. Each names the Job, the step whose cleanup failed,
//! the residue it left behind (a remote path, or an installed bundle), why
//! and when, and the exact typed action that failed. Swift decodes the whole
//! ledger into `[CleanupDebtRecord]` and writes it back with its sorted pretty
//! Foundation encoder (escaped solidus, no trailing newline) through a fresh
//! file renamed into place. A debug HAP's compensation bookkeeping owes a
//! record once per Job and step: one already there, settled or not, is never
//! written again. Every other failed cleanup (a native deployment's) appends
//! its record each time it fails. Settling and retrying a debt
//! (`cleanupDebt.continue`) are not served here.
use crate::artifact_read_owner::ArtifactReadStore;
use crate::session_json;
use serde_json::{Map, Value, json};
use std::io;

const LEDGER: &str = "cleanup-debt.json";
const MAXIMUM_LEDGER: usize = 16 * 1024 * 1024;

/// Swift `CleanupResidue`: what a failed cleanup left behind.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Residue {
    RemotePath(String),
    InstalledBundle(String),
}

impl Residue {
    /// Swift `CleanupResidue.identity`: the bare path, or the bundle under
    /// its own prefix so that it never collides with a path.
    fn identity(&self) -> String {
        match self {
            Self::RemotePath(path) => path.clone(),
            Self::InstalledBundle(bundle) => format!("bundle:{bundle}"),
        }
    }
}

/// Swift `CleanupDebtRecord.identity`: the bundle's, else the path's.
fn identity(record: &Value) -> String {
    match record["bundleName"].as_str() {
        Some(bundle) => format!("bundle:{bundle}"),
        None => record["remotePath"].as_str().unwrap_or_default().to_owned(),
    }
}

/// Swift's `Codable` `CleanupDebtRecord`: its required text members, its
/// optional ones (a `null` reads as absent), and nothing else, which Swift's
/// decoder ignores and its encoder therefore drops.
fn decode(record: &Value) -> Result<Value, String> {
    let fields = record
        .as_object()
        .ok_or("undecodable cleanup debt ledger: a record is not an object")?;
    let mut decoded = Map::new();
    for key in ["jobID", "stepID", "remotePath", "reason", "recordedAtUTC"] {
        let text = fields
            .get(key)
            .and_then(Value::as_str)
            .ok_or_else(|| format!("undecodable cleanup debt ledger: {key}"))?;
        decoded.insert(key.into(), json!(text));
    }
    for key in ["bundleName", "settledAtUTC", "retryAttemptStartedAtUTC"] {
        match fields.get(key) {
            None | Some(Value::Null) => {}
            Some(Value::String(text)) => {
                decoded.insert(key.into(), json!(text));
            }
            Some(_) => return Err(format!("undecodable cleanup debt ledger: {key}")),
        }
    }
    match fields.get("retryOutcomeUnknown") {
        None | Some(Value::Null) => {}
        Some(Value::Bool(flag)) => {
            decoded.insert("retryOutcomeUnknown".into(), json!(flag));
        }
        Some(_) => return Err("undecodable cleanup debt ledger: retryOutcomeUnknown".into()),
    }
    match fields.get("persistedAction") {
        None | Some(Value::Null) => {}
        Some(action) => {
            let valid = action.as_object().is_some_and(|action| {
                action.len() == 2
                    && action.get("kind").is_some_and(Value::is_string)
                    && action.get("arguments").is_some_and(Value::is_object)
            });
            if !valid {
                return Err("undecodable cleanup debt ledger: persistedAction".into());
            }
            decoded.insert("persistedAction".into(), action.clone());
        }
    }
    Ok(Value::Object(decoded))
}

/// Swift `loadCleanupDebt`: every record, outstanding or settled; nothing is
/// owed before the ledger exists.
fn load(artifacts: &ArtifactReadStore) -> Result<Vec<Value>, String> {
    let bytes = match artifacts.root().read(LEDGER, MAXIMUM_LEDGER) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(format!("unreadable cleanup debt ledger: {error}")),
    };
    let records: Vec<Value> = serde_json::from_slice(&bytes)
        .map_err(|error| format!("undecodable cleanup debt ledger: {error}"))?;
    records.iter().map(decode).collect()
}

fn owed_by(record: &Value, job_id: &str, step_id: &str) -> bool {
    record["jobID"] == job_id && record["stepID"] == step_id
}

/// Swift `cleanupDebtRecord(jobID:stepID:)`: the Job's record for a step,
/// settled or not.
pub(crate) fn record(
    artifacts: &ArtifactReadStore,
    job_id: &str,
    step_id: &str,
) -> Result<Option<Value>, String> {
    Ok(load(artifacts)?
        .into_iter()
        .find(|record| owed_by(record, job_id, step_id)))
}

/// Swift `recordCompensationCleanupDebt`: the debt appended once per Job and
/// step. A record already there must name the same residue and the same
/// action, and stays as it is.
pub(crate) fn record_compensation_debt(
    artifacts: &ArtifactReadStore,
    job_id: &str,
    step_id: &str,
    residue: &Residue,
    reason: &str,
    action: &Value,
    now_utc: &str,
) -> Result<(), String> {
    if let Some(existing) = record(artifacts, job_id, step_id)? {
        if identity(&existing) != residue.identity() || existing["persistedAction"] != *action {
            return Err(
                "compensation debt differs from its original residue or exact typed action".into(),
            );
        }
        return Ok(());
    }
    append(artifacts, job_id, step_id, residue, reason, action, now_utc)
}

/// Swift `recordCleanupDebt`: the debt appended as it is owed, whatever the
/// ledger already holds.
pub(crate) fn append(
    artifacts: &ArtifactReadStore,
    job_id: &str,
    step_id: &str,
    residue: &Residue,
    reason: &str,
    action: &Value,
    now_utc: &str,
) -> Result<(), String> {
    let mut records = load(artifacts)?;
    let mut record = json!({
        "jobID": job_id, "stepID": step_id, "reason": reason, "recordedAtUTC": now_utc,
        "persistedAction": action,
    });
    match residue {
        Residue::RemotePath(path) => record["remotePath"] = json!(path),
        Residue::InstalledBundle(bundle) => {
            record["remotePath"] = json!("");
            record["bundleName"] = json!(bundle);
        }
    }
    records.push(record);
    let bytes = session_json::encode_pretty(&Value::Array(records))
        .map_err(|_| "cannot encode the cleanup debt ledger".to_owned())?;
    artifacts
        .root()
        .publish_document(LEDGER, &bytes, MAXIMUM_LEDGER)
        .map_err(|error| format!("cannot persist the cleanup debt ledger: {error:?}"))
}

/// Swift `outstandingCleanupDebt()` for one Job: how many of its records are
/// not settled.
pub(crate) fn outstanding(artifacts: &ArtifactReadStore, job_id: &str) -> Result<usize, String> {
    Ok(load(artifacts)?
        .iter()
        .filter(|record| record["jobID"] == job_id && record.get("settledAtUTC").is_none())
        .count())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_record_keeps_swifts_members_and_drops_what_swift_would_not_encode() {
        let recorded = json!({"jobID": "job-a", "stepID": "cleanup-uninstall",
            "remotePath": "", "bundleName": "com.example.demo", "reason": "r",
            "recordedAtUTC": "2026-09-14T00:00:00Z", "settledAtUTC": null, "extra": 1,
            "persistedAction": {"kind": "hdc.uninstallPackage",
                "arguments": {"bundleName": "com.example.demo"}}});
        let decoded = decode(&recorded).unwrap();
        assert!(decoded.get("extra").is_none() && decoded.get("settledAtUTC").is_none());
        assert_eq!(identity(&decoded), "bundle:com.example.demo");
        let mut malformed = recorded.clone();
        malformed["persistedAction"] = json!({"kind": "hdc.uninstallPackage"});
        assert!(decode(&malformed).is_err());
        malformed = recorded;
        malformed.as_object_mut().unwrap().remove("reason");
        assert!(decode(&malformed).is_err());
    }
}
