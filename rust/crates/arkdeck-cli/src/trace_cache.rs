use crate::{CliError, Invocation};
use serde_json::Value;

pub fn validate_trace_cache_response(
    invocation: &Invocation,
    value: &Value,
) -> Result<(), CliError> {
    if invocation.command != "trace.cache.status" {
        return Ok(());
    }
    let count = |key: &str| value[key].as_u64().filter(|n| *n <= 65_536);
    let valid = || -> Option<()> {
        let fields = value.as_object()?;
        if fields.len() != 6
            || value["schemaVersion"] != "arkdeck.trace-cache-status/1"
            || value["purgeScope"] != "inactiveDerivedDatabases"
        {
            return None;
        }
        let (entries, active, inactive) = (
            count("entryCount")?,
            count("activeEntryCount")?,
            count("inactiveEntryCount")?,
        );
        if active.checked_add(inactive)? != entries {
            return None;
        }
        let text = value["totalByteCount"].as_str()?;
        let bytes = text.parse::<i64>().ok()?;
        (bytes >= 0 && bytes.to_string() == text).then_some(())
    };
    valid().ok_or_else(|| {
        CliError::new(
            "recordUnreadable",
            "Runtime returned an invalid Trace cache status",
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
}
