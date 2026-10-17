//! Read-only augmentation of the complete current-Job snapshot. Both service
//! implementations use the same predicate and request proofs only from their
//! already identity-verified Runtime; no archive, reconcile or operation runs.
use arkdeck_contract::RestartPreflight;
use serde_json::Value;
use std::collections::BTreeMap;

pub(crate) fn classify(
    current: &[Value],
    mut preview: impl FnMut(&str) -> Result<Value, String>,
) -> Result<RestartPreflight, String> {
    // Reject malformed rows before requesting any further proof.
    let malformed = |_| "daemon returned a malformed current Runtime Job".to_owned();
    arkdeck_contract::classify_restart(current).map_err(malformed)?;
    let mut previews = BTreeMap::new();
    for job in current {
        if job["state"] == "interrupted" && job["outcomeUnknown"] == true {
            let id = job["jobId"]
                .as_str()
                .expect("the complete snapshot was classified");
            previews.insert(id.to_owned(), preview(id)?);
        }
    }
    arkdeck_contract::classify_restart_with_archive_previews(current, &previews).map_err(malformed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn row(id: &str, state: &str) -> Value {
        json!({"jobId":id,"state":state,"outcomeUnknown":true,"waitingForHuman":false,
            "outstandingResidueCount":0,"processProgress":null,"finishedAtUtc":"2026-10-04T06:00:00Z"})
    }

    #[test]
    fn missing_archive_method_or_connection_failure_refuses_maintenance() {
        for error in ["unknownMethod", "connection closed"] {
            let result = classify(&[row("archived", "interrupted")], |_| Err(error.to_owned()));
            assert_eq!(result.unwrap_err(), error);
        }
    }

    #[test]
    fn every_archive_is_read_and_malformed_snapshot_prevents_any_request() {
        let rows = [
            row("parked", "waitingForRecovery"),
            row("active", "running"),
            row("archive-a", "interrupted"),
            row("archive-b", "interrupted"),
        ];
        let mut requested = Vec::new();
        let result = classify(&rows, |id| {
            requested.push(id.to_owned());
            Ok(json!({"canArchive":true})) // incomplete proof cannot exempt either row
        })
        .unwrap();
        assert_eq!(requested, ["archive-a", "archive-b"]);
        assert_eq!(
            result.blocking_job_ids,
            ["active", "archive-a", "archive-b"]
        );
        assert_eq!(result.preserved_unknown_job_ids, ["parked"]);
        assert!(
            classify(&[row("archive", "interrupted"), json!({})], |_| {
                panic!("a malformed complete snapshot must fail before any preview")
            })
            .is_err()
        );
    }
}
