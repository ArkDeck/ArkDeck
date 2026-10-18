//! The existing trace.inspect resource over the reviewed Windows CLI's inspect
//! result. Raw Artifacts remain immutable and no Job evidence is published.
use crate::arktrace_envelope::{ArkTraceContract, exact_keys, integer_tokens};
use crate::arktrace_summary::{ascii_sha256, contains_private_path, valid_data_quality};
use crate::{AnalyzerProfile, ArtifactReadStore, JobStore};
use arkdeck_contract::WireError;
use arkdeck_platform::{ToolTermination, VerifiedSource};
use serde_json::{Map, Value, json};
use std::ffi::OsString;
use std::io;
use std::time::Duration;

fn failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(Map::from_iter([
            ("phase".into(), json!("traceInspectionOwner")),
            ("newDispatchCount".into(), json!(0)),
            ("deviceEvidenceCreated".into(), json!(false)),
        ])),
    }
}

pub fn trace_inspection_unavailable() -> WireError {
    failure("operationUnavailable", "Trace inspection is unavailable")
}

fn identifier(value: &str) -> bool {
    crate::job_repository::identifier(value)
}

fn inspection_request(params: &Map<String, Value>) -> Option<(&str, &str, i64)> {
    if !exact_keys(
        params,
        &["owner", "artifactId", "allowSensitive", "timeoutMs"],
    ) || params["allowSensitive"] != true
    {
        return None;
    }
    let owner = params["owner"].as_object()?;
    let job = owner.get("id")?.as_str()?;
    let artifact = params["artifactId"].as_str()?;
    let timeout = params["timeoutMs"].as_i64()?;
    (exact_keys(owner, &["kind", "id"])
        && owner["kind"] == "job"
        && identifier(job)
        && !job.starts_with("imp-")
        && identifier(artifact)
        && (1..=600_000).contains(&timeout))
    .then_some((job, artifact, timeout))
}

pub(crate) struct InspectionInvocation<'a> {
    pub profile: &'a AnalyzerProfile,
    pub source_sha256: &'a str,
    pub source_byte_count: u64,
    pub source_path: &'a str,
    pub timeout_ms: i64,
}

/// Read a closed envelope of exactly this source and invocation. All numbers
/// remain Int64 integer tokens, all warnings are path-free category/scope/count,
/// and the parser, schema and tool identities come from the reviewed profile.
pub(crate) fn valid_inspection_envelope(
    bytes: &[u8],
    invocation: &InspectionInvocation<'_>,
) -> Option<Value> {
    if bytes.len() > 8 * 1024 * 1024
        || crate::strict_json::validate(bytes).is_err()
        || !integer_tokens(bytes)
        || invocation.source_path.is_empty()
        || !ascii_sha256(invocation.source_sha256)
        || !ascii_sha256(&invocation.profile.executable_sha256)
    {
        return None;
    }
    let contract: &ArkTraceContract = invocation.profile.arktrace_summary.as_ref()?;
    let value: Value = serde_json::from_slice(bytes).ok()?;
    let root = value.as_object()?;
    if contains_private_path(&value, invocation.source_path)
        || !exact_keys(
            root,
            &[
                "schemaVersion",
                "tool",
                "request",
                "trace",
                "provenance",
                "limits",
                "dataQuality",
                "truncation",
                "result",
            ],
        )
        || root["schemaVersion"] != "1.0"
        || root["tool"]
            != json!({"name":"arktrace","version":contract.tool_version,"buildRevision":invocation.profile.executable_sha256})
        || root["request"] != json!({"command":"inspect","parameters":{}})
        || root["limits"]
            != json!({"timeoutMs":invocation.timeout_ms,"maxRows":1000,"maxEvents":10000,"maxOutputBytes":8388608})
    {
        return None;
    }
    let trace = root["trace"].as_object()?;
    if !exact_keys(
        trace,
        &[
            "sha256",
            "byteCount",
            "durationNs",
            "parser",
            "schemaFingerprint",
        ],
    ) || trace["sha256"] != invocation.source_sha256
        || trace["byteCount"].as_u64()? != invocation.source_byte_count
        || invocation.source_byte_count == 0
        || trace["durationNs"].as_i64()? < 0
        || !ascii_sha256(trace["schemaFingerprint"].as_str()?)
        || trace["parser"]
            != json!({"name":"trace_streamer","version":contract.parser_version,
            "upstreamRevision":contract.parser_upstream_revision,"binarySha256":contract.parser_sha256})
    {
        return None;
    }
    let provenance = root["provenance"].as_object()?;
    if !exact_keys(
        provenance,
        &[
            "parserAdapterVersion",
            "parserBuildRecipeVersion",
            "schemaAdapterVersion",
            "indexSchemaVersion",
            "upstreamDatabaseSha256",
            "upstreamDatabaseByteCount",
        ],
    ) || provenance["parserAdapterVersion"] != contract.parser_adapter_version
        || provenance["parserBuildRecipeVersion"] != contract.parser_build_recipe_version
        || provenance["schemaAdapterVersion"] != contract.schema_adapter_version
        || provenance["indexSchemaVersion"].as_i64()? != contract.index_schema_version
        || !ascii_sha256(provenance["upstreamDatabaseSha256"].as_str()?)
        || provenance["upstreamDatabaseByteCount"].as_i64()? < 0
    {
        return None;
    }
    let result = root["result"].as_object()?;
    let capabilities = result.get("capabilities")?.as_object()?;
    if !exact_keys(result, &["cacheHit", "capabilities", "indexSchemaVersion"])
        || result["cacheHit"] != false
        || result["indexSchemaVersion"].as_i64()? != contract.index_schema_version
        || !exact_keys(
            capabilities,
            &[
                "cpuScheduling",
                "threadStates",
                "namedSlices",
                "cpuCounters",
                "processCounters",
            ],
        )
        || !capabilities.values().all(Value::is_boolean)
        || !valid_data_quality(root.get("dataQuality"))
    {
        return None;
    }
    let warnings = root["dataQuality"]["warnings"].as_array()?;
    let truncated = warnings
        .iter()
        .any(|warning| warning["category"] == "probeTruncated");
    let sections = if truncated {
        json!(["dataQualityProbes"])
    } else {
        json!([])
    };
    if root["truncation"] != json!({"truncated":truncated,"sections":sections}) {
        return None;
    }
    Some(value)
}

/// RuntimeTraceInspectionResourceHandler's order and fixed failure classes,
/// now answered by the same CLI engine that serves the two analyzer operations.
pub fn inspect_trace_artifact(
    jobs: &JobStore,
    artifacts: &ArtifactReadStore,
    profile: &AnalyzerProfile,
    params: &Map<String, Value>,
) -> Result<Value, WireError> {
    if !profile.holds() {
        return Err(trace_inspection_unavailable());
    }
    let (job_id,artifact_id,timeout_ms) = inspection_request(params).ok_or_else(||failure("invalidInput",
        "Trace inspection requires an exact Job/Artifact, sensitive opt-in, and bounded timeout"))?;
    jobs.read_snapshot(job_id).map_err(|error| {
        if error.code == "notFound" {
            failure("resourceNotFound", "Trace Job owner does not exist")
        } else {
            failure(&error.code, &error.message)
        }
    })?;
    let metadata = artifacts.inspect(job_id, artifact_id).map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            failure(
                "resourceNotFound",
                "Trace Artifact does not exist for this Job",
            )
        } else {
            failure(
                "artifactIntegrityFailed",
                "Trace Artifact metadata is inconsistent",
            )
        }
    })?;
    let digest = metadata["sha256"].as_str().filter(|s| ascii_sha256(s));
    let count = metadata["byteCount"].as_u64().filter(|count| *count > 0);
    if metadata["status"].get("published").is_none()
        || !matches!(
            metadata["sourceOperation"].as_str(),
            Some("capture.diagnostics@1" | "capture.diagnostic-session@1")
        )
        || metadata["name"] != "trace.htrace"
        || metadata["mediaType"] != "application/octet-stream"
        || metadata["privacy"] != "sensitive"
        || metadata["redactionApplied"] != false
        || digest.is_none()
        || count.is_none()
    {
        return Err(failure(
            "invalidInput",
            "selected Artifact is not the exact raw diagnostics Trace product",
        ));
    }
    let lease = artifacts
        .owned_lease(job_id, artifact_id)
        .map_err(|error| {
            if error.starts_with("artifactNotFound(") {
                failure(
                    "resourceNotFound",
                    "Trace Artifact does not exist for this Job",
                )
            } else {
                failure(
                    "artifactIntegrityFailed",
                    "Trace Artifact metadata is inconsistent",
                )
            }
        })?;
    if lease.artifact_id != artifact_id || lease.job_id != job_id || lease.row != metadata {
        return Err(failure(
            "artifactIntegrityFailed",
            "Trace Artifact lease identity drifted",
        ));
    }
    let (Some(digest), Some(count)) = (digest, count) else {
        return Err(failure(
            "artifactIntegrityFailed",
            "Trace Artifact immutable identity is invalid",
        ));
    };
    let source = VerifiedSource::open(&lease.path, digest, count).map_err(|_| {
        failure(
            "artifactIntegrityFailed",
            "Trace Artifact immutable identity is invalid",
        )
    })?;
    let source_path = source.inode_path();
    let arguments: Vec<_> = [
        "inspect".into(),
        "--json".into(),
        "--no-cache".into(),
        "--timeout-ms".into(),
        timeout_ms.to_string(),
        "--max-rows".into(),
        "1000".into(),
        "--max-events".into(),
        "10000".into(),
        "--max-output-bytes".into(),
        "8388608".into(),
        source_path.clone(),
    ]
    .into_iter()
    .map(OsString::from)
    .collect();
    let execution = crate::arktrace_windows::run_profile(
        profile,
        &arguments,
        Duration::from_millis(timeout_ms as u64),
        8 * 1024 * 1024,
        &|| false,
    )
    .map_err(|_| {
        failure(
            "operationFailed",
            "Trace inspection failed without creating evidence",
        )
    })?;
    if execution.termination == ToolTermination::TimedOut {
        return Err(failure(
            "operationFailed",
            "Trace inspection timed out and was drained",
        ));
    }
    if execution.termination != ToolTermination::Exited(0)
        || execution.truncated
        || !execution.stderr.is_empty()
    {
        return Err(failure(
            "operationFailed",
            "Trace inspection failed without creating evidence",
        ));
    }
    let result = valid_inspection_envelope(
        &execution.stdout,
        &InspectionInvocation {
            profile,
            source_sha256: digest,
            source_byte_count: count,
            source_path: &source_path,
            timeout_ms,
        },
    )
    .ok_or_else(|| {
        failure(
            "recordUnreadable",
            "Trace inspection returned an invalid report",
        )
    })?;
    if !artifacts.payload_matches(&lease)
        || artifacts.inspect(job_id, artifact_id).ok().as_ref() != Some(&metadata)
    {
        return Err(failure(
            "artifactIntegrityFailed",
            "Trace Artifact lease identity drifted",
        ));
    }
    let revision = crate::arktrace_windows::reviewed_revision(profile).map_err(|_| {
        failure(
            "operationFailed",
            "Trace inspection failed without creating evidence",
        )
    })?;
    let contract = profile
        .arktrace_summary
        .as_ref()
        .ok_or_else(trace_inspection_unavailable)?;
    let quality = result["dataQuality"]["warnings"]
        .as_array()
        .ok_or_else(|| {
            failure(
                "recordUnreadable",
                "Trace inspection returned an invalid report",
            )
        })?;
    let issues:Vec<_> = quality.iter().map(|warning|json!({"category":warning["category"],"scope":warning["scope"],"count":warning["count"]})).collect();
    let report = json!({
        "schemaVersion":"arkdeck.trace-inspection/1","owner":params["owner"],
        "source":{"artifactId":artifact_id,"artifactDigest":digest,"byteCount":count.to_string(),
            "sourceOperation":metadata["sourceOperation"],"name":"trace.htrace","mediaType":"application/octet-stream","privacy":"sensitive"},
        "engine":{"name":"ArkTrace","version":contract.tool_version,"build":"1","sourceRevision":revision},
        "parser":{"name":"trace_streamer","version":contract.parser_version,"upstreamRevision":contract.parser_upstream_revision,
            "binarySha256":contract.parser_sha256,"adapterVersion":contract.parser_adapter_version,"buildRecipeVersion":contract.parser_build_recipe_version},
        "schema":{"fingerprint":result["trace"]["schemaFingerprint"],"provenance":{"adapterVersion":contract.schema_adapter_version,
            "indexVersion":contract.index_schema_version,"upstreamDatabaseSha256":result["provenance"]["upstreamDatabaseSha256"],
            "upstreamDatabaseByteCount":result["provenance"]["upstreamDatabaseByteCount"].as_i64().unwrap_or(-1).to_string()}},
        "trace":{"durationNs":result["trace"]["durationNs"].as_i64().unwrap_or(-1).to_string(),"capabilities":result["result"]["capabilities"]},
        "dataQuality":{"status":result["dataQuality"]["status"],"issues":issues},
        "storageMode":"ephemeral","deviceEvidenceCreated":false,
    });
    if serde_json::to_vec(&report).map_or(true, |bytes| bytes.len() > 8 * 1024 * 1024 - 4096)
        || contains_private_path(&report, &source_path)
    {
        return Err(failure(
            "recordUnreadable",
            "Trace inspection returned an invalid report",
        ));
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inspection_requires_exact_job_artifact_opt_in_and_integer_budget() {
        let request = json!({"owner":{"kind":"job","id":"job-inspection"},
            "artifactId":"ART-00000000000000000000000000000000","allowSensitive":true,"timeoutMs":120000});
        assert_eq!(
            inspection_request(request.as_object().unwrap()),
            Some((
                "job-inspection",
                "ART-00000000000000000000000000000000",
                120000
            ))
        );
        for (path, value) in [
            ("/owner/kind", json!("import")),
            ("/owner/id", json!("imp-one")),
            ("/owner/id", json!("../job")),
            ("/artifactId", json!("a:stream")),
            ("/allowSensitive", json!(false)),
            ("/allowSensitive", json!(1)),
            ("/timeoutMs", json!(0)),
            ("/timeoutMs", json!(600001)),
            ("/timeoutMs", json!(120000.0)),
        ] {
            let mut altered = request.clone();
            *altered.pointer_mut(path).unwrap() = value;
            assert!(
                inspection_request(altered.as_object().unwrap()).is_none(),
                "{path}"
            );
        }
        let mut missing = request.clone();
        missing.as_object_mut().unwrap().remove("allowSensitive");
        assert!(inspection_request(missing.as_object().unwrap()).is_none());
        let mut extra = request;
        extra["path"] = json!(r"C:\caller\trace.htrace");
        assert!(inspection_request(extra.as_object().unwrap()).is_none());
    }
}
