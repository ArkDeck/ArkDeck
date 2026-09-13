use crate::{CliError, Invocation};
use serde_json::Value;

pub fn validate_trace_cache_response(
    invocation: &Invocation,
    value: &Value,
) -> Result<(), CliError> {
    if !matches!(
        invocation.command,
        "trace.cache.status" | "trace.cache.purge"
    ) {
        return Ok(());
    }
    let count = |object: &Value, key: &str| object[key].as_u64().filter(|n| *n <= 65_536);
    let inventory = |object: &Value, fields: usize| -> Option<(u64, i64)> {
        if object.as_object()?.len() != fields {
            return None;
        }
        let entries = count(object, "entryCount")?;
        if count(object, "activeEntryCount")?.checked_add(count(object, "inactiveEntryCount")?)?
            != entries
        {
            return None;
        }
        let text = object["totalByteCount"].as_str()?;
        let bytes = text.parse::<i64>().ok()?;
        (bytes >= 0 && bytes.to_string() == text).then_some((entries, bytes))
    };
    let purge = invocation.command == "trace.cache.purge";
    let valid = || -> Option<()> {
        if value["purgeScope"] != "inactiveDerivedDatabases" {
            return None;
        }
        if !purge {
            if value["schemaVersion"] != "arkdeck.trace-cache-status/1" {
                return None;
            }
            return inventory(value, 6).map(|_| ());
        }
        if value.as_object()?.len() != 9
            || value["schemaVersion"] != "arkdeck.trace-cache-purge/1"
            || value["originalTraceArtifactRemovalCount"] != 0
        {
            return None;
        }
        let (before, _) = inventory(&value["before"], 4)?;
        inventory(&value["after"], 4)?;
        count(value, "recoveredPrivateDirectoryCount")?;
        count(value, "removedOrphanOwnerMarkerCount")?;
        let selected = count(value, "removedEntryCount")?
            .checked_add(count(value, "skippedActiveEntryCount")?)?;
        (selected <= before).then_some(())
    };
    valid().ok_or_else(|| {
        CliError::new(
            if purge {
                "outcomeUnknown"
            } else {
                "recordUnreadable"
            },
            if purge {
                "Runtime returned an invalid Trace cache purge receipt; no request was replayed"
            } else {
                "Runtime returned an invalid Trace cache status"
            },
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn existing_status_command_is_closed_and_counts_must_reconcile() {
        let args = ["trace", "cache", "status"].map(str::to_owned);
        let invocation = crate::parse(&args).unwrap();
        assert_eq!(invocation.method, "trace.cache.status");
        let valid = json!({"schemaVersion":"arkdeck.trace-cache-status/1", "purgeScope":"inactiveDerivedDatabases",
            "entryCount":2,"activeEntryCount":1,"inactiveEntryCount":1,"totalByteCount":"512"});
        validate_trace_cache_response(&invocation, &valid).unwrap();
        for (key, value) in [
            ("activeEntryCount", json!(3)),
            ("inactiveEntryCount", json!(-1)),
            ("totalByteCount", json!("0512")),
            ("totalByteCount", json!("9223372036854775808")),
            ("purgeScope", json!("all")),
            ("schemaVersion", json!("future")),
            ("extra", json!(true)),
        ] {
            let mut changed = valid.clone();
            changed[key] = value;
            assert_eq!(
                validate_trace_cache_response(&invocation, &changed)
                    .unwrap_err()
                    .code,
                "recordUnreadable"
            );
        }
        let mut extra = args.to_vec();
        extra.extend(["--root".into(), "/tmp".into()]);
        assert_eq!(crate::parse(&extra).unwrap_err().code, "invalidOption");
    }
    #[test]
    fn purge_receipts_are_closed_and_unconfirmed_answers_never_enable_replay() {
        let invocation = crate::parse(&["trace".into(), "cache".into(), "purge".into()]).unwrap();
        let inventory = json!({"entryCount":1,"activeEntryCount":0,"inactiveEntryCount":1,"totalByteCount":"16"});
        let value = json!({"schemaVersion":"arkdeck.trace-cache-purge/1","purgeScope":"inactiveDerivedDatabases",
            "before":inventory,"after":{"entryCount":0,"activeEntryCount":0,"inactiveEntryCount":0,"totalByteCount":"0"},
            "recoveredPrivateDirectoryCount":0,"removedOrphanOwnerMarkerCount":0,"removedEntryCount":1,
            "skippedActiveEntryCount":0,"originalTraceArtifactRemovalCount":0});
        validate_trace_cache_response(&invocation, &value).unwrap();
        for (pointer, replacement) in [
            ("/originalTraceArtifactRemovalCount", json!(1)),
            ("/removedEntryCount", json!(2)),
            ("/after/totalByteCount", json!("00")),
            ("/before/activeEntryCount", json!(2)),
            ("/purgeScope", json!("all")),
        ] {
            let mut changed = value.clone();
            *changed.pointer_mut(pointer).unwrap() = replacement;
            assert_eq!(
                validate_trace_cache_response(&invocation, &changed)
                    .unwrap_err()
                    .code,
                "outcomeUnknown"
            );
        }
        for error in [
            arkdeck_client::ClientError::Transport(std::io::Error::other("lost reply")),
            arkdeck_client::ClientError::Contract(
                arkdeck_contract::ContractError::ContractMismatch,
            ),
            arkdeck_client::ClientError::ConnectionUnusable,
        ] {
            let error = CliError::from_client(error, "trace.cache.purge");
            assert_eq!(error.code, "outcomeUnknown");
            assert_eq!(error.exit_code(), 75);
            assert_ne!(error.details.get("retryable"), Some(&json!(true)));
        }
        for args in [
            ["trace", "cache", "purge", "--root", "/tmp"],
            ["trace", "cache", "purge", "--confirm", "yes"],
        ] {
            assert!(crate::parse(&args.map(str::to_owned)).is_err());
        }
    }
}
