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
//! its record each time it fails. `cleanupDebt.list` reads the ledger as the
//! daemon lists it; settling and retrying a debt (`cleanupDebt.continue`) are
//! not served here.
use crate::artifact_read_owner::ArtifactReadStore;
use crate::session_json;
use crate::strict_json::swift_quoted;
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
            // `PersistedTypedProviderAction`'s synthesized decoder reads its
            // two members and ignores any other, which its encoder drops.
            let (Some(kind), Some(arguments)) = (
                action.get("kind").filter(|kind| kind.is_string()),
                action
                    .get("arguments")
                    .filter(|arguments| arguments.is_object()),
            ) else {
                return Err("undecodable cleanup debt ledger: persistedAction".into());
            };
            decoded.insert(
                "persistedAction".into(),
                json!({"kind": kind, "arguments": arguments}),
            );
        }
    }
    Ok(Value::Object(decoded))
}

/// Swift `loadCleanupDebt`: every record, outstanding or settled; nothing is
/// owed before the ledger exists. Swift reports every failure to read or
/// decode it as one undecodable ledger.
fn load(artifacts: &ArtifactReadStore) -> Result<Vec<Value>, String> {
    let bytes = match artifacts.root().read(LEDGER, MAXIMUM_LEDGER) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(format!("undecodable cleanup debt ledger: {error}")),
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

/// The Jobs `outstandingCleanupDebt()` names: every Job still owing a
/// cleanup, whose Artifacts the retention sweep keeps.
pub(crate) fn outstanding_jobs(
    artifacts: &ArtifactReadStore,
) -> Result<std::collections::BTreeSet<String>, String> {
    Ok(load(artifacts)?
        .iter()
        .filter(|record| record.get("settledAtUTC").is_none())
        .filter_map(|record| record["jobID"].as_str().map(str::to_owned))
        .collect())
}

/// The daemon's `cleanupDebt.list` (Swift `listCleanupDebt`, encoded by
/// `encodeCleanupDebt`): every record not yet settled, ordered by Job, then
/// remote path (empty for a bundle), then when it was owed, each with its
/// residue's identity and whether a retry of it ever started. A ledger that
/// cannot be read or decoded refuses the whole list with the store error
/// Swift renders; nothing is written.
pub fn list_cleanup_debt(artifacts: &ArtifactReadStore) -> Result<Value, String> {
    let records =
        load(artifacts).map_err(|detail| format!("indexCorrupted({})", swift_quoted(&detail)))?;
    Ok(listing(records))
}

fn listing(records: Vec<Value>) -> Value {
    let text = |record: &Value, key: &str| record[key].as_str().unwrap_or_default().to_owned();
    let order = |record: &Value| {
        (
            text(record, "jobID"),
            text(record, "remotePath"),
            text(record, "recordedAtUTC"),
        )
    };
    let mut owed: Vec<Value> = records
        .into_iter()
        .filter(|record| record.get("settledAtUTC").is_none())
        .collect();
    owed.sort_by_cached_key(order);
    owed.iter()
        .map(|record| {
            json!({
                "jobId": record["jobID"], "stepId": record["stepID"],
                "remotePath": record["remotePath"],
                "bundleName": record.get("bundleName").cloned().unwrap_or(Value::Null),
                "identity": identity(record), "reason": record["reason"],
                "recordedAtUtc": record["recordedAtUTC"],
                "retryOutcomeUnknown": record["retryOutcomeUnknown"] == true
                    || record.get("retryAttemptStartedAtUTC").is_some(),
            })
        })
        .collect()
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
        let mut extended = recorded.clone();
        extended["persistedAction"]["note"] = json!("dropped");
        assert_eq!(
            decode(&extended).unwrap()["persistedAction"],
            recorded["persistedAction"]
        );
        malformed = recorded;
        malformed.as_object_mut().unwrap().remove("reason");
        assert!(decode(&malformed).is_err());
    }

    #[test]
    fn the_list_encodes_the_owed_records_in_swifts_order() {
        let owed = |job: &str, step: &str, path: &str, recorded: &str| {
            json!({"jobID": job, "stepID": step, "remotePath": path, "reason": "r",
                "recordedAtUTC": recorded})
        };
        let mut first_bundle = owed("job-b", "cleanup-uninstall", "", "2026-09-14T00:00:00Z");
        first_bundle["bundleName"] = json!("com.example.demo");
        let mut second_bundle = owed("job-b", "cleanup-other", "", "2026-09-14T00:00:00Z");
        second_bundle["bundleName"] = json!("com.example.other");
        let mut started = owed("job-a", "cleanup-z", "/data/z", "2026-09-14T00:00:00Z");
        started["retryAttemptStartedAtUTC"] = json!("2026-09-14T00:00:05Z");
        let mut unknown = owed("job-a", "cleanup-y", "/data/y", "2026-09-14T00:00:02Z");
        unknown["retryOutcomeUnknown"] = json!(true);
        let mut settled = owed("job-a", "cleanup-a", "/data/a", "2026-09-14T00:00:00Z");
        settled["settledAtUTC"] = json!("2026-09-14T00:00:03Z");
        let earlier = owed("job-a", "cleanup-y", "/data/y", "2026-09-14T00:00:01Z");
        let ledger = [
            first_bundle,
            started,
            unknown,
            settled,
            second_bundle,
            earlier,
        ];
        let listed = listing(
            ledger
                .iter()
                .map(|record| decode(record).unwrap())
                .collect(),
        );
        // By Job, then path, then when owed; equal keys keep the ledger's
        // order, and a settled record is not listed.
        let expected: Value = serde_json::from_str(
            r#"[
            {"jobId": "job-a", "stepId": "cleanup-y", "remotePath": "/data/y", "bundleName": null,
             "identity": "/data/y", "reason": "r", "recordedAtUtc": "2026-09-14T00:00:01Z",
             "retryOutcomeUnknown": false},
            {"jobId": "job-a", "stepId": "cleanup-y", "remotePath": "/data/y", "bundleName": null,
             "identity": "/data/y", "reason": "r", "recordedAtUtc": "2026-09-14T00:00:02Z",
             "retryOutcomeUnknown": true},
            {"jobId": "job-a", "stepId": "cleanup-z", "remotePath": "/data/z", "bundleName": null,
             "identity": "/data/z", "reason": "r", "recordedAtUtc": "2026-09-14T00:00:00Z",
             "retryOutcomeUnknown": true},
            {"jobId": "job-b", "stepId": "cleanup-uninstall", "remotePath": "",
             "bundleName": "com.example.demo", "identity": "bundle:com.example.demo",
             "reason": "r", "recordedAtUtc": "2026-09-14T00:00:00Z", "retryOutcomeUnknown": false},
            {"jobId": "job-b", "stepId": "cleanup-other", "remotePath": "",
             "bundleName": "com.example.other", "identity": "bundle:com.example.other",
             "reason": "r", "recordedAtUtc": "2026-09-14T00:00:00Z", "retryOutcomeUnknown": false}
            ]"#,
        )
        .unwrap();
        assert_eq!(listed, expected);
    }

    #[test]
    fn an_undecodable_ledger_refuses_the_whole_list_and_a_missing_one_owes_nothing() {
        use std::fs;
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("cleanup-debt-list-{nonce:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let artifacts = ArtifactReadStore::open(&root).unwrap();
        assert_eq!(list_cleanup_debt(&artifacts).unwrap(), json!([]));
        // An owner-only file, as the host store reads every one.
        fs::write(
            root.join(LEDGER),
            br#"[{"jobID": "job-a", "stepID": "cleanup", "remotePath": 1}]"#,
        )
        .unwrap();
        fs::set_permissions(root.join(LEDGER), fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            list_cleanup_debt(&artifacts).unwrap_err(),
            "indexCorrupted(\"undecodable cleanup debt ledger: remotePath\")"
        );
        drop(artifacts);
        fs::remove_dir_all(root).unwrap();
    }
}
