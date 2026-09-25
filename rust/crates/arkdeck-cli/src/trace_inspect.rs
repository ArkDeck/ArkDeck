//! `arkdeck trace inspect`: Swift `RuntimeCLI.runTrace`'s `inspect`. One
//! `trace.inspect` for an exact Job-owned Trace Artifact, with sensitive
//! access granted by the caller and the inspection bounded in time. The answer
//! is checked as Swift's `RuntimeTraceInspectionProjection` checks it, and must
//! name the owner and Artifact asked for, before it is emitted as the Runtime
//! gave it. The check follows `CLITraceInspectOracleContractTests`.
use crate::CliError;
use serde_json::{Map, Value, json};

/// Swift's default inspection time and its ceiling.
const DEFAULT_TIMEOUT: &str = "2m";
const MAXIMUM_TIMEOUT_MS: u64 = 600_000;
/// The client waits this much longer than the inspection may take.
const CLIENT_MARGIN_MS: u64 = 5_000;
/// Swift `RuntimeTraceInspectionReport`'s bound on data-quality issues.
const MAXIMUM_ISSUES: usize = 4_096;

/// Swift `RuntimeTraceInspectionQualityIssue`'s categories.
const CATEGORIES: [&str; 6] = [
    "probeTruncated",
    "invalidValue",
    "clampedValue",
    "droppedValue",
    "referentialIntegrity",
    "unavailableValue",
];

/// Swift `ArkTraceSummaryEnvelopeValidator.machineQualityScopes`, sorted.
pub const MACHINE_QUALITY_SCOPES: [&str; 51] = [
    "callstack.cookie",
    "callstack.depth",
    "callstack.dur",
    "callstack.identity",
    "callstack.parent_id",
    "callstack.ts",
    "callstack.value",
    "cpu_measure_filter.cpu",
    "cpu_measure_filter.id",
    "cpu_measure_filter.name",
    "cpu_measure_filter.unit",
    "measure.dur",
    "measure.filter_id",
    "measure.optional",
    "measure.ts",
    "measure.value",
    "process.end_ts",
    "process.lifecycle",
    "process.name",
    "process.start_ts",
    "process_measure_filter.id",
    "process_measure_filter.ipid",
    "process_measure_filter.name",
    "process_measure_filter.unit",
    "sched_slice.cpu",
    "sched_slice.dur",
    "sched_slice.identity",
    "sched_slice.overlap",
    "sched_slice.ts",
    "sched_slice.value",
    "stat",
    "stat.count",
    "stat.event_name",
    "stat.source",
    "stat.stat_type",
    "thread.end_ts",
    "thread.ipid",
    "thread.lifecycle",
    "thread.name",
    "thread.processName",
    "thread.start_ts",
    "thread_state.cpu",
    "thread_state.dur",
    "thread_state.identity",
    "thread_state.state",
    "thread_state.ts",
    "thread_state.value",
    "timeline.counter",
    "timeline.counter.duration",
    "timeline.density.dominantThread",
    "timeline.density.occupancy",
];

fn invalid_input(message: &str) -> CliError {
    CliError::new("invalidInput", message)
}

/// The parse: Swift's registry requires the three options, and its grammar
/// bounds `--timeout` at the inspection's ceiling. It refuses otherwise before
/// any handler runs.
pub(crate) fn configure(
    command: &str,
    fields: &Map<String, Value>,
    help: bool,
) -> Result<(), CliError> {
    if help || command != "trace.inspect" {
        return Ok(());
    }
    if ["jobId", "artifactId", "allowSensitive"]
        .iter()
        .any(|key| !fields.contains_key(*key))
    {
        return Err(CliError::new(
            "invalidOption",
            "trace inspect requires --job, --artifact and --allow-sensitive",
        ));
    }
    if let Some(timeout) = fields.get("timeout")
        && !timeout
            .as_str()
            .and_then(crate::read_only_resources::duration)
            .is_some_and(|milliseconds| milliseconds <= MAXIMUM_TIMEOUT_MS)
    {
        return Err(CliError::new(
            "invalidOption",
            "trace inspect --timeout must be a duration of at most 10m",
        ));
    }
    Ok(())
}

/// Swift's handler before anything is sent, in its order: the exact
/// identities and the sensitive grant, the inspection time, then the Job
/// owner. The request `trace.inspect` carries, and the client's own wait.
pub fn inspection_request(
    fields: &Map<String, Value>,
) -> Result<(Map<String, Value>, u64), CliError> {
    let text = |key: &str| fields.get(key).and_then(Value::as_str);
    let (Some(job), Some(artifact)) = (text("jobId"), text("artifactId")) else {
        return Err(invalid_input(
            "trace inspect requires exact --job/--artifact identities and --allow-sensitive",
        ));
    };
    if !crate::read_only_resources::identifier(job)
        || !crate::read_only_resources::identifier(artifact)
        || fields.get("allowSensitive") != Some(&json!(true))
    {
        return Err(invalid_input(
            "trace inspect requires exact --job/--artifact identities and --allow-sensitive",
        ));
    }
    let timeout = crate::read_only_resources::duration(text("timeout").unwrap_or(DEFAULT_TIMEOUT))
        .filter(|milliseconds| *milliseconds <= MAXIMUM_TIMEOUT_MS)
        .ok_or_else(|| invalid_input("Trace inspection timeout must be 1ms...10m"))?;
    // Swift `ArtifactOwnerReference`: a Job owner never carries an Import's
    // identity.
    if job.starts_with("imp-") {
        return Err(invalid_input("an Import identity cannot select a Job"));
    }
    let request = Map::from_iter([
        ("owner".to_owned(), json!({"kind": "job", "id": job})),
        ("artifactId".to_owned(), json!(artifact)),
        ("allowSensitive".to_owned(), json!(true)),
        ("timeoutMs".to_owned(), json!(timeout)),
    ]);
    Ok((request, timeout + CLIENT_MARGIN_MS))
}

/// Swift's check of the Runtime's answer: a Trace inspection, of the owner
/// and Artifact `request` asked for.
pub fn validate_inspection(value: &Value, request: &Map<String, Value>) -> Result<(), CliError> {
    let (owner, artifact) = inspection_projection(value).ok_or_else(|| {
        CliError::new(
            "recordUnreadable",
            "Runtime returned an invalid Trace inspection",
        )
    })?;
    if Some(&owner) != request.get("owner") || Some(&json!(artifact)) != request.get("artifactId") {
        return Err(CliError::new(
            "recordUnreadable",
            "Trace inspection belongs to another source",
        ));
    }
    Ok(())
}

/// Swift `RuntimeTraceInspectionProjection.init`: the owner and Artifact a
/// closed, well-formed Trace inspection names, or `None`.
pub fn inspection_projection(value: &Value) -> Option<(Value, String)> {
    let root = closed(
        value,
        &[
            "schemaVersion",
            "owner",
            "source",
            "engine",
            "parser",
            "schema",
            "trace",
            "dataQuality",
            "storageMode",
            "deviceEvidenceCreated",
        ],
    )?;
    let owner = &root["owner"];
    let owner_fields = closed(owner, &["kind", "id"])?;
    let owner_id = owner_fields["id"].as_str()?;
    if owner_fields["kind"] != "job"
        || !crate::read_only_resources::identifier(owner_id)
        || owner_id.starts_with("imp-")
        || root["schemaVersion"] != "arkdeck.trace-inspection/1"
        || root["storageMode"] != "ephemeral"
        || root["deviceEvidenceCreated"] != false
    {
        return None;
    }
    let source = closed(
        &root["source"],
        &[
            "artifactId",
            "artifactDigest",
            "byteCount",
            "sourceOperation",
            "name",
            "mediaType",
            "privacy",
        ],
    )?;
    let artifact = source["artifactId"].as_str()?;
    if !crate::read_only_resources::identifier(artifact)
        || !sha256(&source["artifactDigest"])
        || !canonical_integer(&source["byteCount"]).is_some_and(|count| count > 0)
        || source["sourceOperation"] != "capture.diagnostics@1"
        || source["name"] != "trace.htrace"
        || source["mediaType"] != "application/octet-stream"
        || source["privacy"] != "sensitive"
    {
        return None;
    }
    let engine = closed(
        &root["engine"],
        &["name", "version", "build", "sourceRevision"],
    )?;
    if engine["name"] != "ArkTrace"
        || !safe(&engine["version"])
        || !safe(&engine["build"])
        || !lowercase_hex(&engine["sourceRevision"], 40)
    {
        return None;
    }
    let parser = closed(
        &root["parser"],
        &[
            "name",
            "version",
            "upstreamRevision",
            "binarySha256",
            "adapterVersion",
            "buildRecipeVersion",
        ],
    )?;
    if !safe(&parser["name"])
        || !safe(&parser["version"])
        || !lowercase_hex(&parser["upstreamRevision"], 40)
        || !sha256(&parser["binarySha256"])
        || !safe(&parser["adapterVersion"])
        || !safe(&parser["buildRecipeVersion"])
    {
        return None;
    }
    let schema = closed(&root["schema"], &["fingerprint", "provenance"])?;
    let provenance = closed(
        &schema["provenance"],
        &[
            "adapterVersion",
            "indexVersion",
            "upstreamDatabaseSha256",
            "upstreamDatabaseByteCount",
        ],
    )?;
    if !sha256(&schema["fingerprint"])
        || !safe(&provenance["adapterVersion"])
        || !provenance["indexVersion"]
            .as_i64()
            .is_some_and(|index| index >= 0)
        || !sha256(&provenance["upstreamDatabaseSha256"])
        || !canonical_integer(&provenance["upstreamDatabaseByteCount"])
            .is_some_and(|count| count >= 0)
    {
        return None;
    }
    let trace = closed(&root["trace"], &["durationNs", "capabilities"])?;
    let capabilities = closed(
        &trace["capabilities"],
        &[
            "cpuScheduling",
            "threadStates",
            "namedSlices",
            "cpuCounters",
            "processCounters",
        ],
    )?;
    if !canonical_integer(&trace["durationNs"]).is_some_and(|duration| duration >= 0)
        || !capabilities.values().all(Value::is_boolean)
    {
        return None;
    }
    let quality = closed(&root["dataQuality"], &["status", "issues"])?;
    let issues = quality["issues"].as_array()?;
    if issues.len() > MAXIMUM_ISSUES {
        return None;
    }
    let mut previous: Option<(&str, &str, i64)> = None;
    for issue in issues {
        let fields = closed(issue, &["category", "scope", "count"])?;
        let category = fields["category"].as_str()?;
        let scope = match &fields["scope"] {
            Value::Null => None,
            Value::String(scope) => Some(scope.as_str()),
            _ => return None,
        };
        let count = match &fields["count"] {
            Value::Null => None,
            count => Some(count.as_i64()?),
        };
        if !CATEGORIES.contains(&category)
            || scope.is_some_and(|scope| !MACHINE_QUALITY_SCOPES.contains(&scope))
            || count.is_some_and(|count| count < 0)
        {
            return None;
        }
        // Ordered by (category, scope, count), no two alike: an absent scope
        // sorts as "", an absent count below every count.
        let key = (category, scope.unwrap_or(""), count.unwrap_or(i64::MIN));
        if previous.is_some_and(|previous| previous >= key) {
            return None;
        }
        previous = Some(key);
    }
    let status = quality["status"].as_str()?;
    if status != if issues.is_empty() { "ok" } else { "warnings" } {
        return None;
    }
    Some((owner.clone(), artifact.to_owned()))
}

/// An object with exactly `keys`.
fn closed<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a Map<String, Value>> {
    value.as_object().filter(|fields| {
        fields.len() == keys.len() && keys.iter().all(|key| fields.contains_key(*key))
    })
}

/// Swift `Int64(text)` whose spelling is its own.
fn canonical_integer(value: &Value) -> Option<i64> {
    let text = value.as_str()?;
    text.parse::<i64>()
        .ok()
        .filter(|number| number.to_string() == text)
}

fn lowercase_hex(value: &Value, count: usize) -> bool {
    value.as_str().is_some_and(|text| {
        text.len() == count
            && text
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    })
}

fn sha256(value: &Value) -> bool {
    lowercase_hex(value, 64)
}

/// Swift `RuntimeTraceInspectionParser.safe`: non-empty, at most 128 UTF-8
/// bytes, no solidus or backslash, and no scalar of Foundation's
/// `controlCharacters` (Cc and Cf). Off macOS, where Swift's CLI does not run,
/// the format characters are not known to this check.
fn safe(value: &Value) -> bool {
    value.as_str().is_some_and(|text| {
        !text.is_empty()
            && text.len() <= 128
            && !text.contains(['/', '\\'])
            && !text.chars().any(control)
    })
}

#[cfg(target_os = "macos")]
fn control(scalar: char) -> bool {
    arkdeck_platform::host_control_character(scalar)
}

#[cfg(not(target_os = "macos"))]
fn control(scalar: char) -> bool {
    scalar.is_control()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn more_issues_than_swift_bounds_are_refused() {
        let recorded: Value = include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/trace.inspect.jsonl"
        )
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .find(|frame| frame["ok"] == true)
        .unwrap()["result"]
            .clone();
        assert!(inspection_projection(&recorded).is_some());
        let issues = |count: usize| {
            let mut value = recorded.clone();
            value["dataQuality"] = json!({"status": "warnings", "issues": (0..count)
                .map(|index| json!({"category": "invalidValue", "scope": null, "count": index}))
                .collect::<Vec<_>>()});
            value
        };
        assert!(inspection_projection(&issues(MAXIMUM_ISSUES)).is_some());
        assert!(inspection_projection(&issues(MAXIMUM_ISSUES + 1)).is_none());
    }
}
