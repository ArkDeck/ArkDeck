//! Read-only consumers of Runtime facts. No catalog fallback, polling or replay.
use crate::{CliError, Invocation, valid_correlation};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
pub(super) fn invalid() -> CliError {
    CliError::new(
        "recordUnreadable",
        "Runtime returned an invalid read-only resource",
    )
}
fn identifier(s: &str) -> bool {
    valid_correlation(s) && !s.contains(':')
}
pub(super) fn duration(s: &str) -> Option<u64> {
    for (suffix, scale) in [("ms", 1), ("s", 1000), ("m", 60_000), ("h", 3_600_000)] {
        if let Some(n) = s.strip_suffix(suffix) {
            if n.is_empty() || n.starts_with('0') || !n.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            return n
                .parse::<u64>()
                .ok()?
                .checked_mul(scale)
                .filter(|n| *n <= 86_400_000);
        }
    }
    None
}
pub(crate) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<Option<u64>, CliError> {
    if help
        || !matches!(
            command,
            "operation.describe"
                | "operation.example"
                | "job.status"
                | "job.list"
                | "job.show"
                | "job.evidence"
                | "job.timeline"
                | "job.events"
                | "job.run"
                | "job.result"
        )
    {
        return Ok(None);
    }
    if command == "job.list" {
        crate::job_resources::configure_list(fields)?;
    } else {
        let key = if matches!(command, "operation.describe" | "operation.example") {
            "operation"
        } else {
            "jobId"
        };
        let text = fields.get(key).and_then(Value::as_str).ok_or_else(|| {
            CliError::new(
                "invalidOption",
                format!(
                    "{command} requires --{}",
                    if key == "operation" {
                        "operation"
                    } else {
                        "job"
                    }
                ),
            )
        })?;
        if matches!(command, "operation.describe" | "operation.example") {
            let reference = text.to_owned();
            fields.remove("operation");
            fields.insert("reference".into(), json!(reference));
            return Ok(None);
        }
        if !identifier(text) {
            return Err(CliError::new(
                "invalidInput",
                "an exact Job identity is required",
            ));
        }
    }
    if command == "job.events" {
        crate::job_events::configure(fields)?;
    }
    if command == "job.timeline" {
        crate::job_resources::configure_list(fields)?;
    }
    let timeout = fields.remove("timeout").unwrap_or(json!("30s"));
    duration(timeout.as_str().unwrap_or_default())
        .map(Some)
        .ok_or_else(|| {
            CliError::new(
                "invalidOption",
                "timeout must be a positive duration bounded by 24h",
            )
        })
}
pub(super) fn keys(v: &Value, expected: &[&str]) -> bool {
    v.as_object()
        .is_some_and(|v| v.len() == expected.len() && expected.iter().all(|k| v.contains_key(*k)))
}
fn member(v: &Value, values: &[&str]) -> bool {
    v.as_str().is_some_and(|s| values.contains(&s))
}
pub(super) fn date(v: &Value) -> bool {
    let Some(s) = v.as_str() else {
        return false;
    };
    let b = s.as_bytes();
    if b.len() < 20
        || !b.is_ascii()
        || !b[..19].iter().enumerate().all(|(i, c)| match i {
            4 | 7 => *c == b'-',
            10 => *c == b'T',
            13 | 16 => *c == b':',
            _ => c.is_ascii_digit(),
        })
    {
        return false;
    }
    let n = |a, b| s[a..b].parse::<u32>().unwrap();
    let (y, m, d) = (n(0, 4), n(5, 7), n(8, 10));
    let days = match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) => 29,
        2 => 28,
        _ => 0,
    };
    if y == 0 || d == 0 || d > days || n(11, 13) > 23 || n(14, 16) > 59 || n(17, 19) > 59 {
        return false;
    }
    let mut tail = &s[19..];
    if let Some(f) = tail.strip_prefix('.') {
        let count = f.bytes().take_while(u8::is_ascii_digit).count();
        if count == 0 {
            return false;
        }
        tail = &f[count..];
    }
    tail == "Z"
        || (tail.len() == 6
            && matches!(tail.as_bytes()[0], b'+' | b'-')
            && tail.as_bytes()[3] == b':'
            && tail[1..3].parse::<u32>().is_ok_and(|n| n < 24)
            && tail[4..6].parse::<u32>().is_ok_and(|n| n < 60))
}
fn publication(v: &Value) -> bool {
    if !keys(
        v,
        &["state", "manifestSha256", "catalogGeneration", "reasonCode"],
    ) {
        return false;
    }
    if v["state"] == "published" {
        return v["reasonCode"].is_null()
            && v["manifestSha256"].as_str().is_some_and(|s| {
                s.len() == 64
                    && s.bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
            && v["catalogGeneration"]
                .as_str()
                .is_some_and(|s| s.parse::<u64>().is_ok_and(|n| n.to_string() == s));
    }
    v["manifestSha256"].is_null()
        && v["catalogGeneration"].is_null()
        && match v["state"].as_str() {
            Some("pending") => member(
                &v["reasonCode"],
                &["jobNotTerminal", "waitingForStorage", "finalizationPending"],
            ),
            Some("failed") => member(
                &v["reasonCode"],
                &[
                    "storageUnavailable",
                    "sourceIntegrityFailed",
                    "identityChanged",
                    "contractViolation",
                ],
            ),
            Some("outcomeUnknown") => v["reasonCode"] == "publicationUncertain",
            Some("unavailable") => v["reasonCode"] == "noCurrentPublicationRecord",
            _ => false,
        }
}
fn typed_failure(v: &Value) -> bool {
    keys(
        v,
        &[
            "schemaVersion",
            "code",
            "category",
            "retryability",
            "recovery",
        ],
    ) && v["schemaVersion"] == "1.0.0"
        && member(
            &v["code"],
            &[
                "executionFailed",
                "executionConfirmedNotPerformed",
                "artifactPublicationFailed",
                "artifactFinalizationFailed",
                "reconciliationConfirmedNotPerformed",
                "outcomeUnknown",
                "cancelled",
                "interrupted",
                "legacyFailure",
            ],
        )
        && member(
            &v["category"],
            &[
                "execution",
                "externalTool",
                "storage",
                "cancelled",
                "unknownOutcome",
                "runtime",
            ],
        )
        && member(
            &v["retryability"],
            &["notAutomatic", "runtimeDecisionRequired"],
        )
        && member(
            &v["recovery"],
            &[
                "none",
                "inspectJob",
                "awaitRuntimeReconciliation",
                "submitNewTypedRequestAfterRuntimeProof",
            ],
        )
}
/// Check the compiled request contract before connecting. Frame decoding only
/// checks the control envelope, so it cannot reject unpublished method fields.
pub fn validate_read_only_request(invocation: &Invocation) -> Result<(), CliError> {
    if matches!(
        invocation.command,
        "operation.describe"
            | "operation.example"
            | "job.status"
            | "job.list"
            | "job.show"
            | "job.evidence"
            | "job.timeline"
            | "job.events"
            | "job.run"
            | "job.result"
    ) {
        arkdeck_contract::validate_method_value(
            invocation.method,
            "request",
            &Value::Object(invocation.params.clone().unwrap_or_default()),
        )
        .map_err(|error| {
            CliError::from_client(
                arkdeck_client::ClientError::Contract(error),
                invocation.method,
            )
        })?;
    }
    Ok(())
}

pub fn validate_read_only_response(invocation: &Invocation, v: &Value) -> Result<(), CliError> {
    if !matches!(
        invocation.command,
        "operation.describe"
            | "operation.example"
            | "job.status"
            | "job.list"
            | "job.show"
            | "job.evidence"
            | "job.timeline"
            | "job.events"
            | "job.run"
            | "job.result"
    ) {
        return Ok(());
    }
    // Structural validation also protects direct callers of this consumer.
    arkdeck_contract::validate_method_value(invocation.method, "result", v)
        .map_err(|_| invalid())?;
    let params = invocation.params.as_ref().ok_or_else(invalid)?;
    if matches!(
        invocation.command,
        "operation.describe" | "operation.example"
    ) {
        return if v["reference"] == params["reference"] {
            Ok(())
        } else {
            Err(invalid())
        };
    }
    if invocation.command == "job.list" {
        return crate::job_resources::validate_list(params, v);
    }
    if invocation.command == "job.events" {
        return crate::job_events::validate(params, v);
    }
    if invocation.command == "job.timeline" {
        return crate::job_resources::validate_timeline_page(params, v);
    }
    let id = params["jobId"].as_str().ok_or_else(invalid)?;
    if invocation.command == "job.show" {
        return crate::job_resources::validate_show(id, v);
    }
    if invocation.command == "job.evidence" {
        return validate_evidence(id, v);
    }
    if invocation.command == "job.result" {
        return validate_result(id, v);
    }
    validate_job_status(id, v)
}

pub(super) fn validate_job_status(id: &str, v: &Value) -> Result<(), CliError> {
    // The enclosing method's generated schema has already checked the wire
    // types. Nested list/show records use their own recorded schema rather
    // than borrowing the standalone status method's sample-derived branches.
    if !keys(
        v,
        &[
            "schemaVersion",
            "jobId",
            "operation",
            "targetId",
            "state",
            "outcome",
            "waitingForHuman",
            "outcomeUnknown",
            "outstandingResidueCount",
            "executionMode",
            "sessionId",
            "threadId",
            "workspaceKind",
            "actualEffect",
            "createdAtUtc",
            "startedAtUtc",
            "finishedAtUtc",
            "supersededByRecoveryEpochId",
            "recoveryEpochId",
            "resolvedByTargetAliasResolutionId",
            "sessionPublication",
            "nextAction",
            "failure",
            "processProgress",
        ],
    ) {
        return Err(invalid());
    }
    let state = v["state"].as_str().ok_or_else(invalid)?;
    let terminal = terminal_job_state(state);
    let unknown = v["outcomeUnknown"].as_bool().ok_or_else(invalid)?;
    let human = v["waitingForHuman"].as_bool().ok_or_else(invalid)?;
    if !known_job_state(state)
        || v["schemaVersion"] != "arkdeck.job-status/1"
        || v["jobId"] != id
        || !identifier(id)
        || v["outcome"] != if unknown { "outcomeUnknown" } else { state }
        || !date(&v["createdAtUtc"])
        || !publication(&v["sessionPublication"])
    {
        return Err(invalid());
    }
    let next = &v["nextAction"];
    if next["owner"] != json!({"kind":"job","id":id}) {
        return Err(invalid());
    }
    let base = ["kind", "owner", "resource", "reasonCode"];
    let uncertain = unknown || ["waitingForRecovery", "reconciling"].contains(&state);
    let finalizing = !uncertain
        && state == "finalizing"
        && v["operation"] == "debug.hap@1"
        && typed_failure(&v["failure"])
        && v["failure"]["code"] != "outcomeUnknown";
    let (kind, reason) = if uncertain {
        ("reconcile", "recovery.outcomeUnknown")
    } else if finalizing {
        ("reconcile", "job.finalizationPending")
    } else if terminal {
        ("readResult", "job.resultAvailable")
    } else {
        ("wait", "job.running")
    };
    if human
        || next["resource"] != next["owner"]
        || next["kind"] != kind
        || next["reasonCode"] != reason
        || !keys(
            next,
            if kind == "wait" {
                &["kind", "owner", "resource", "reasonCode", "retryAfter"]
            } else {
                &base
            },
        )
        || (kind == "wait"
            && !next["retryAfter"]
                .as_str()
                .is_some_and(|s| duration(s).is_some()))
    {
        return Err(invalid());
    }
    // Query success preserves attention facts; it is not execution success.
    Ok(())
}

fn terminal_job_state(state: &str) -> bool {
    [
        "planned",
        "succeeded",
        "recovered",
        "failed",
        "cancelled",
        "interrupted",
    ]
    .contains(&state)
}

pub(super) fn known_job_state(state: &str) -> bool {
    terminal_job_state(state)
        || [
            "queued",
            "preflight",
            "running",
            "waitingForDevice",
            "awaitingRebindConfirmation",
            "planning",
            "cancelRequested",
            "cancellingAtSafeBoundary",
            "waitingForRecovery",
            "reconciling",
            "recoveringByCompleteOverwrite",
            "resumeAtConfirmedSafeBoundary",
            "userAbandonRequested",
            "finalizing",
        ]
        .contains(&state)
}

/// Render the Runtime's example verbatim; no local Catalog is consulted.
pub fn project_read_only_response(
    invocation: &Invocation,
    value: Value,
) -> Result<Value, CliError> {
    validate_read_only_response(invocation, &value)?;
    if invocation.command == "operation.example" {
        return value
            .get("exampleRequest")
            .filter(|v| !v.is_null())
            .cloned()
            .ok_or_else(|| {
                let mut error = CliError::new(
                    "blockedByProductDefect",
                    "the Runtime publishes no example request",
                );
                if let Some(reference) = invocation.params.as_ref().and_then(|p| p.get("reference"))
                {
                    error.details.insert("operation".into(), reference.clone());
                }
                error
            });
    }
    Ok(value)
}

fn validate_evidence(id: &str, v: &Value) -> Result<(), CliError> {
    if !keys(
        v,
        &[
            "schemaVersion",
            "jobId",
            "operationReference",
            "catalogDigest",
            "targetId",
            "bindingRevision",
            "providerId",
            "actualEffect",
            "authority",
            "observation",
            "actualStepKinds",
            "executionMode",
            "terminalState",
            "outcomeUnknown",
            "startedAtUtc",
            "firstEvidenceStepAtUtc",
            "finishedAtUtc",
            "recoveryEpoch",
            "parameters",
            "traceProbeBefore",
            "traceProbeAfter",
            "artifacts",
            "blockers",
            "status",
            "inventoryAvailable",
            "missingRequiredArtifacts",
        ],
    ) || v["schemaVersion"] != "arkdeck.job-evidence/1"
        || v["jobId"] != id
        || !v["catalogDigest"].as_str().is_some_and(|s| {
            s.len() == 64
                && s.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
        || !v["status"].is_string()
        || !v["blockers"].as_array().is_some_and(|a| {
            a.iter().all(Value::is_string) && (v["status"] == "verified") == a.is_empty()
        })
        || !v["artifacts"].is_array()
        || !v["inventoryAvailable"].is_boolean()
        || !v["missingRequiredArtifacts"]
            .as_array()
            .is_some_and(|a| a.iter().all(|v| v.as_str().is_some_and(|s| !s.is_empty())))
    {
        return Err(invalid());
    }
    Ok(())
}

/// Swift `CLIJobReadValidation.validate` for `job.result`: the terminal
/// status, its evidence, every inventory and outstanding cleanup row, and the
/// one next action they leave.
fn validate_result(id: &str, v: &Value) -> Result<(), CliError> {
    let job = &v["job"];
    if !keys(
        v,
        &[
            "schemaVersion",
            "job",
            "terminal",
            "outcomeUnknown",
            "evidence",
            "artifacts",
            "cleanup",
            "nextAction",
        ],
    ) || v["schemaVersion"] != "arkdeck.job-result/1"
        || v["terminal"] != true
        || !job["state"].as_str().is_some_and(terminal_job_state)
        || v["outcomeUnknown"] != job["outcomeUnknown"]
    {
        return Err(invalid());
    }
    validate_job_status(id, job)?;
    validate_evidence(id, &v["evidence"])?;
    let digest = crate::session_resources::digest;
    let named = |v: &Value| v.as_str().is_some_and(|s| !s.is_empty());
    let decimal = |v: &Value| {
        v.as_str()
            .is_some_and(|s| s.parse::<i64>().is_ok_and(|n| n >= 0 && n.to_string() == s))
    };
    let mut artifacts = BTreeSet::new();
    for row in v["artifacts"].as_array().ok_or_else(invalid)? {
        let artifact = row["artifactId"]
            .as_str()
            .filter(|s| identifier(s))
            .ok_or_else(invalid)?;
        if !keys(
            row,
            &[
                "artifactId",
                "owner",
                "reference",
                "name",
                "mediaType",
                "byteCount",
                "sha256",
                "privacy",
                "status",
                "bytesVerified",
            ],
        ) || row["owner"] != json!({"kind": "job", "id": id})
            || !artifacts.insert(artifact)
            || row["reference"] != format!("arkdeck-artifact://{id}/{artifact}")
            // Only a row recording a missing product has no digest.
            || !(digest(&row["sha256"]) || (row["status"] == "missing" && row["sha256"] == ""))
            || !decimal(&row["byteCount"])
            || !row["bytesVerified"].is_boolean()
            || !named(&row["name"])
            || !named(&row["mediaType"])
            || !member(&row["privacy"], &["standard", "sensitive"])
            || !member(&row["status"], &["published", "missing", "truncated"])
        {
            return Err(invalid());
        }
    }
    let mut debts = BTreeSet::new();
    for row in v["cleanup"].as_array().ok_or_else(invalid)? {
        let debt = row["cleanupDebtId"].as_str().ok_or_else(invalid)?;
        if !keys(
            row,
            &[
                "cleanupDebtId",
                "jobId",
                "stepId",
                "recordedAtUtc",
                "outcomeUnknown",
            ],
        ) || row["jobId"] != id
            || !row["outcomeUnknown"].is_boolean()
            || !debts.insert(debt)
            || !debt
                .strip_prefix("cleanup-")
                .is_some_and(|hex| digest(&json!(hex)))
            || !named(&row["stepId"])
            || !date(&row["recordedAtUtc"])
        {
            return Err(invalid());
        }
    }
    let next = &v["nextAction"];
    // An unknown outcome keeps the status's reconcile action; otherwise the
    // next action names an outstanding cleanup row, or there is none.
    let consistent = if v["outcomeUnknown"] == true {
        next == &job["nextAction"]
    } else if debts.is_empty() {
        next.is_null()
    } else {
        keys(next, &["kind", "owner", "resource", "reasonCode"])
            && next["kind"] == "cleanup"
            && next["owner"] == json!({"kind": "job", "id": id})
            && keys(&next["resource"], &["kind", "id"])
            && next["resource"]["kind"] == "cleanupDebt"
            && next["resource"]["id"]
                .as_str()
                .is_some_and(|debt| debts.contains(debt))
            && next["reasonCode"] == "recovery.cleanupDebt"
    };
    if consistent { Ok(()) } else { Err(invalid()) }
}

/// The exit a validated `arkdeck.job-evidence/1` earns: only an explicitly
/// verified result exits 0, and a Job without a result yet is read again
/// later. Any other status, a future one included, needs attention.
pub fn evidence_exit(evidence: &Value) -> u8 {
    match evidence["status"].as_str() {
        Some("verified") => 0,
        Some("resultNotReady") => 75,
        _ => 2,
    }
}

/// Swift `CLIJobReadValidation` for a validated `job.result`: an unknown
/// outcome exits 75, since it is reconciled and never replayed; otherwise
/// evidence that needs attention decides, and then the Job's terminal state.
pub fn result_exit(result: &Value) -> u8 {
    if result["outcomeUnknown"] == true {
        return 75;
    }
    match evidence_exit(&result["evidence"]) {
        0 => crate::run_exit(&result["job"]).map_or(0, |(code, _)| code),
        code => code,
    }
}
