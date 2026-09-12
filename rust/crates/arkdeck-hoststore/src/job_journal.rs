//! Closed current Journal decoding for metadata reads and the future single
//! Runtime journal owner. Decoding never recovers, authorizes or dispatches.
use crate::session_manifest::{ManifestError, Object, Result, object, require, text};
use arkdeck_contract::{sha256_hex, strict_json};
use serde_json::{Value, json};

pub const JOURNAL_KINDS: &[&str] = &[
    "jobCreated",
    "stateTransition",
    "stepIntent",
    "stepOutcome",
    "compensationIntent",
    "compensationOutcome",
    "bindingCandidate",
    "bindingConfirmed",
    "bindingRejected",
    "serverGenerationChanged",
    "sleep",
    "wake",
    "reconcileStarted",
    "reconcileOutcome",
    "abandonIntent",
    "abandonOutcome",
    "warning",
    "error",
    "finalized",
];
const MAX_RECORD: usize = 16 * 1024 * 1024;
const STATES: &[&str] = &[
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
    "planned",
    "succeeded",
    "recovered",
    "failed",
    "cancelled",
    "interrupted",
];

#[derive(Debug)]
pub struct JournalEvent {
    value: Value,
}
impl JournalEvent {
    pub fn decode(bytes: &[u8]) -> std::result::Result<Self, crate::DecodeError> {
        if bytes.is_empty() || bytes.len() > MAX_RECORD {
            return Err(crate::DecodeError::Size);
        }
        let value = strict_json(bytes).map_err(|_| crate::DecodeError::Shape)?;
        validate(&value).map_err(|_| crate::DecodeError::Shape)?;
        Ok(Self { value })
    }
    pub fn value(&self) -> &Value {
        &self.value
    }
    pub fn sequence(&self) -> u64 {
        self.value["sequence"].as_u64().expect("validated sequence")
    }
    pub fn job_id(&self) -> &str {
        self.value["jobId"].as_str().expect("validated identity")
    }
    pub fn session_id(&self) -> &str {
        self.value["sessionId"]
            .as_str()
            .expect("validated identity")
    }
    pub fn event_id(&self) -> &str {
        self.value["eventId"].as_str().expect("validated identity")
    }
    pub fn kind(&self) -> &str {
        self.value["kind"].as_str().expect("validated kind")
    }
    pub fn projection(&self) -> std::result::Result<Value, crate::DecodeError> {
        for key in ["eventId", "jobId", "sessionId", "timestamp", "stepId"] {
            if self.value[key].as_str().is_some_and(|s| s.len() > 512) {
                return Err(crate::DecodeError::Size);
            }
        }
        let mut result = json!({"jobId":self.job_id(), "sessionId":self.session_id(),
            "journalKind":self.kind(), "timestamp":self.value["timestamp"],
            "stepId":self.value.get("stepId").unwrap_or(&Value::Null),
            "attempt":self.value["attempt"].as_i64().map(|v|v.to_string()),
            "bindingRevision":self.value["bindingRevision"].as_i64().map(|v|v.to_string())});
        if self.kind() == "stateTransition" {
            result["fromState"] = self.value["payload"]["from"].clone();
            result["toState"] = self.value["payload"]["to"].clone();
        }
        Ok(result)
    }
}

fn keys(row: &Object, required: &[&str], optional: &[&str]) -> Result<()> {
    require(
        required.iter().all(|key| row.contains_key(*key))
            && row
                .keys()
                .all(|key| required.contains(&key.as_str()) || optional.contains(&key.as_str())),
    )
}
fn string<'a>(row: &'a Object, key: &str) -> Result<&'a str> {
    let s = text(row, key)?;
    require(!s.is_empty())?;
    Ok(s)
}
fn choice<'a>(row: &'a Object, key: &str, choices: &[&str]) -> Result<&'a str> {
    let s = text(row, key)?;
    require(choices.contains(&s))?;
    Ok(s)
}
fn integer(row: &Object, key: &str, minimum: i64) -> Result<i64> {
    let value = row
        .get(key)
        .and_then(Value::as_i64)
        .ok_or(ManifestError::Invalid)?;
    require(value >= minimum)?;
    Ok(value)
}
fn nullable_integer(row: &Object, key: &str) -> Result<Option<i64>> {
    match row.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value.as_i64().map(Some).ok_or(ManifestError::Invalid),
    }
}
fn nullable_string<'a>(row: &'a Object, key: &str, nonempty: bool) -> Result<Option<&'a str>> {
    match row.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if !nonempty || !s.is_empty() => Ok(Some(s)),
        _ => Err(ManifestError::Invalid),
    }
}
fn strings(row: &Object, key: &str, minimum: usize) -> Result<()> {
    let values = row
        .get(key)
        .and_then(Value::as_array)
        .ok_or(ManifestError::Invalid)?;
    require(values.len() >= minimum && values.iter().all(Value::is_string))
}
fn lower_hash(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn nonempty_object<'a>(row: &'a Object, key: &str) -> Result<&'a Object> {
    let value = object(row.get(key).ok_or(ManifestError::Invalid)?)?;
    require(!value.is_empty())?;
    Ok(value)
}
fn transition(from: &str, to: &str) -> bool {
    let allowed: &[&str] = match from {
        "queued" => &["preflight", "cancelRequested", "finalizing"],
        "preflight" => &[
            "running",
            "planning",
            "cancelRequested",
            "finalizing",
            "waitingForRecovery",
        ],
        "running" => &[
            "waitingForDevice",
            "cancelRequested",
            "finalizing",
            "waitingForRecovery",
            "recoveringByCompleteOverwrite",
        ],
        "waitingForDevice" => &[
            "running",
            "awaitingRebindConfirmation",
            "cancelRequested",
            "finalizing",
            "waitingForRecovery",
        ],
        "awaitingRebindConfirmation" => &[
            "waitingForDevice",
            "cancelRequested",
            "finalizing",
            "waitingForRecovery",
        ],
        "planning" => &["cancelRequested", "finalizing"],
        "cancelRequested" => &[
            "cancellingAtSafeBoundary",
            "finalizing",
            "waitingForRecovery",
        ],
        "cancellingAtSafeBoundary" => &["cancelled", "finalizing", "waitingForRecovery"],
        "waitingForRecovery" => &[
            "reconciling",
            "recoveringByCompleteOverwrite",
            "userAbandonRequested",
        ],
        "reconciling" => &[
            "resumeAtConfirmedSafeBoundary",
            "recoveringByCompleteOverwrite",
            "finalizing",
            "waitingForRecovery",
        ],
        "recoveringByCompleteOverwrite" => &["cancelRequested", "finalizing", "waitingForRecovery"],
        "resumeAtConfirmedSafeBoundary" => {
            &["running", "planning", "finalizing", "waitingForRecovery"]
        }
        "userAbandonRequested" => &["interrupted", "waitingForRecovery"],
        "finalizing" => &[
            "planned",
            "succeeded",
            "recovered",
            "failed",
            "waitingForRecovery",
        ],
        _ => &[],
    };
    allowed.contains(&to)
}

/// Apply the same immutable WorkflowStep registry minima as Swift decoding.
/// This only validates a historical typed payload; it grants no execution use.
fn workflow(value: &Value, compensation: bool) -> Result<(&str, bool, String)> {
    let row = object(value)?;
    let ordinary = [
        "id",
        "kind",
        "effect",
        "cancellation",
        "bindingRequirement",
        "arguments",
        "compensationDescriptors",
    ];
    let compensating = [
        "id",
        "kind",
        "effect",
        "cancellation",
        "bindingRequirement",
        "arguments",
        "trigger",
        "argumentsHash",
    ];
    keys(
        row,
        if compensation {
            &compensating
        } else {
            &ordinary
        },
        &[],
    )?;
    let id = string(row, "id")?;
    require(crate::session_manifest::identifier(id))?;
    let kind = string(row, "kind")?;
    let arguments = object(&row["arguments"])?;
    let policy = crate::session_step_arguments::validate(kind, arguments)?;
    choice(
        row,
        "effect",
        &["hostOnly", "readOnly", "deviceMutation", "destructive"],
    )?;
    choice(
        row,
        "cancellation",
        &["immediate", "atSafeBoundary", "criticalNonInterruptible"],
    )?;
    let binding = choice(row, "bindingRequirement", &["none", "confirmedDevice"])?;
    if !compensation && policy.exact_binding {
        require(usize::from(binding == "confirmedDevice") == policy.binding)?;
    }
    let confirmed = binding == "confirmedDevice" || policy.binding == 1;
    let hash = sha256_hex(
        &crate::session_json::encode(&row["arguments"]).map_err(|_| ManifestError::Invalid)?,
    );
    if compensation {
        require(
            [
                "stopRemoteCapture",
                "restoreParameter",
                "cleanupOwnedRemotePath",
                "removePortForward",
                "stopApplication",
                "uninstallPackage",
            ]
            .contains(&kind),
        )?;
        choice(
            row,
            "trigger",
            &["onSuccess", "onFailure", "onCancel", "onAnyTerminal"],
        )?;
        require(text(row, "argumentsHash")?.to_ascii_lowercase() == hash)?;
    } else {
        for descriptor in row["compensationDescriptors"]
            .as_array()
            .ok_or(ManifestError::Invalid)?
        {
            workflow(descriptor, true)?;
        }
    }
    Ok((id, confirmed, hash))
}
fn target(value: &Value, confirmed: bool, revision: Option<i64>) -> Result<()> {
    let row = object(value)?;
    keys(
        row,
        &["scope", "targetId", "connectKey", "identitySnapshotHash"],
        &[],
    )?;
    let scope = choice(row, "scope", &["host", "server", "device"])?;
    string(row, "targetId")?;
    let connect = nullable_string(row, "connectKey", true)?;
    let hash = nullable_string(row, "identitySnapshotHash", false)?;
    require(hash.is_none_or(lower_hash))?;
    require(if confirmed {
        revision.is_some_and(|n| n > 0) && scope == "device" && connect.is_some() && hash.is_some()
    } else {
        revision.is_none()
    })
}

fn validate(value: &Value) -> Result<()> {
    let row = object(value)?;
    let kind = choice(row, "kind", JOURNAL_KINDS)?;
    let mut required = vec![
        "schemaVersion",
        "eventId",
        "sequence",
        "sessionId",
        "jobId",
        "timestamp",
        "kind",
        "payload",
    ];
    match kind {
        "stepIntent" | "compensationIntent" => {
            required.extend(["stepId", "attempt", "bindingRevision", "argumentsHash"])
        }
        "stepOutcome" | "compensationOutcome" => required.extend(["stepId", "attempt"]),
        "bindingConfirmed" | "reconcileOutcome" => required.push("bindingRevision"),
        _ => (),
    }
    keys(
        row,
        &required,
        &[
            "accumulatedElapsedDurationNanoseconds",
            "accumulatedActiveDurationNanoseconds",
        ],
    )?;
    require(text(row, "schemaVersion")? == "1.0.0")?;
    for key in ["eventId", "sessionId", "jobId"] {
        string(row, key)?;
    }
    integer(row, "sequence", 0)?;
    require(crate::session_time::session_timestamp(text(row, "timestamp")?).is_some())?;
    for key in [
        "accumulatedElapsedDurationNanoseconds",
        "accumulatedActiveDurationNanoseconds",
    ] {
        require(nullable_integer(row, key)?.is_none_or(|n| n >= 0))?;
    }
    let revision = nullable_integer(row, "bindingRevision")?;
    let step = nullable_string(row, "stepId", true)?;
    if [
        "stepIntent",
        "compensationIntent",
        "stepOutcome",
        "compensationOutcome",
    ]
    .contains(&kind)
    {
        require(step.is_some())?;
        integer(row, "attempt", 1)?;
    }
    if ["stepIntent", "compensationIntent"].contains(&kind) {
        require(nullable_string(row, "argumentsHash", true)?.is_some_and(lower_hash))?;
    }
    let p = object(&row["payload"])?;
    match kind {
        "jobCreated" => {
            keys(
                p,
                &[
                    "executionMode",
                    "executionAuthority",
                    "initialState",
                    "coreBaseline",
                ],
                &[],
            )?;
            choice(p, "executionMode", &["execute", "planOnly", "simulated"])?;
            choice(
                p,
                "executionAuthority",
                &["interactiveUser", "standardAgent", "controlledHardwareLab"],
            )?;
            require(text(p, "initialState")? == "queued")?;
            let baseline = text(p, "coreBaseline")?
                .strip_prefix("CORE-")
                .ok_or(ManifestError::Invalid)?;
            let components: Vec<_> = baseline.split('.').collect();
            require(
                components.len() == 3
                    && components
                        .iter()
                        .all(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())),
            )?;
        }
        "stateTransition" => {
            keys(p, &["from", "to", "reason"], &["triggerEventId"])?;
            require(transition(text(p, "from")?, text(p, "to")?))?;
            string(p, "reason")?;
            nullable_string(p, "triggerEventId", true)?;
        }
        "stepIntent" | "compensationIntent" => {
            let compensation = kind == "compensationIntent";
            keys(
                p,
                if compensation {
                    &["compensationOfStepId", "descriptor", "target"]
                } else {
                    &["step", "target"]
                },
                &[],
            )?;
            if compensation {
                string(p, "compensationOfStepId")?;
            }
            let (id, confirmed, hash) = workflow(
                &p[if compensation { "descriptor" } else { "step" }],
                compensation,
            )?;
            require(step == Some(id) && row["argumentsHash"] == hash)?;
            target(&p["target"], confirmed, revision)?;
        }
        "stepOutcome" | "compensationOutcome" => {
            let mut fields = vec!["correlatesToIntentEventId", "result", "outcomeCertainty"];
            if kind == "compensationOutcome" {
                fields.extend(["compensationOfStepId", "descriptorId"]);
            }
            keys(p, &fields, &["semanticCode", "summary"])?;
            string(p, "correlatesToIntentEventId")?;
            if kind == "compensationOutcome" {
                string(p, "compensationOfStepId")?;
                require(step == Some(string(p, "descriptorId")?))?;
            }
            choice(
                p,
                "result",
                &["succeeded", "failed", "cancelled", "timedOut"],
            )?;
            choice(p, "outcomeCertainty", &["confirmed", "outcomeUnknown"])?;
            nullable_string(p, "semanticCode", false)?;
            nullable_string(p, "summary", false)?;
        }
        "bindingCandidate" => {
            keys(
                p,
                &[
                    "candidateId",
                    "connectKey",
                    "transport",
                    "identitySnapshot",
                    "evidence",
                    "ambiguity",
                ],
                &[],
            )?;
            string(p, "candidateId")?;
            nullable_string(p, "connectKey", false)?;
            choice(p, "transport", &["usb", "tcp", "uart", "synthetic"])?;
            nonempty_object(p, "identitySnapshot")?;
            strings(p, "evidence", 0)?;
            choice(p, "ambiguity", &["unambiguous", "ambiguous"])?;
        }
        "bindingConfirmed" => {
            require(revision.is_some_and(|n| n > 0))?;
            keys(p, &["candidateEventId", "binding"], &[])?;
            string(p, "candidateEventId")?;
            let b = object(&p["binding"])?;
            keys(
                b,
                &[
                    "connectKey",
                    "transport",
                    "identitySnapshot",
                    "evidence",
                    "confirmedBy",
                    "channelProtection",
                ],
                &[],
            )?;
            let connect = nullable_string(b, "connectKey", false)?;
            let transport = choice(b, "transport", &["usb", "tcp", "uart", "synthetic"])?;
            nonempty_object(b, "identitySnapshot")?;
            strings(b, "evidence", 1)?;
            let by = choice(b, "confirmedBy", &["corePolicy", "user", "simulation"])?;
            let channel = choice(
                b,
                "channelProtection",
                &[
                    "encryptedVerified",
                    "unverifiedAssumeUnprotected",
                    "notApplicable",
                ],
            )?;
            require(if transport == "synthetic" {
                connect.is_none() && by == "simulation" && channel == "notApplicable"
            } else {
                connect.is_some_and(|s| !s.is_empty())
                    && by != "simulation"
                    && channel != "notApplicable"
            })?;
        }
        "bindingRejected" => {
            keys(p, &["candidateEventId", "reason", "evidence"], &[])?;
            string(p, "candidateEventId")?;
            choice(
                p,
                "reason",
                &[
                    "identityMismatch",
                    "userRejected",
                    "ambiguous",
                    "staleCandidate",
                    "serverGenerationChanged",
                    "policyBlocked",
                ],
            )?;
            strings(p, "evidence", 0)?;
        }
        "serverGenerationChanged" => {
            keys(
                p,
                &[
                    "endpoint",
                    "previousGeneration",
                    "currentGeneration",
                    "ownership",
                    "reason",
                ],
                &[],
            )?;
            string(p, "endpoint")?;
            string(p, "reason")?;
            integer(p, "previousGeneration", 0)?;
            integer(p, "currentGeneration", 0)?;
            choice(p, "ownership", &["external", "arkDeckManaged", "unknown"])?;
        }
        "sleep" | "wake" => {
            let mut fields = vec!["elapsedDurationNanoseconds", "activeDurationNanoseconds"];
            if kind == "wake" {
                fields.extend(["sleepEventId", "throughputSegmentReset"]);
            }
            keys(p, &fields, &[])?;
            integer(p, "elapsedDurationNanoseconds", 0)?;
            integer(p, "activeDurationNanoseconds", 0)?;
            if kind == "wake" {
                string(p, "sleepEventId")?;
                require(p["throughputSegmentReset"] == true)?;
            }
        }
        "reconcileStarted" => {
            keys(
                p,
                &[
                    "recoveryAttemptId",
                    "sourceState",
                    "lastDurableSequence",
                    "trigger",
                ],
                &[],
            )?;
            string(p, "recoveryAttemptId")?;
            choice(p, "sourceState", STATES)?;
            integer(p, "lastDurableSequence", 0)?;
            choice(
                p,
                "trigger",
                &["startup", "manual", "deviceReturned", "providerRecovery"],
            )?;
        }
        "reconcileOutcome" => {
            keys(
                p,
                &[
                    "recoveryAttemptId",
                    "result",
                    "nextState",
                    "outcomeCertainty",
                    "safeBoundaryConfirmed",
                    "evidence",
                ],
                &[],
            )?;
            string(p, "recoveryAttemptId")?;
            strings(p, "evidence", 0)?;
            let next = text(p, "nextState")?;
            let certainty = text(p, "outcomeCertainty")?;
            let safe = p["safeBoundaryConfirmed"]
                .as_bool()
                .ok_or(ManifestError::Invalid)?;
            let confirmed = certainty == "confirmed" && safe;
            require(match text(p, "result")? {
                "resumeAtConfirmedSafeBoundary" => {
                    next == "resumeAtConfirmedSafeBoundary"
                        && confirmed
                        && revision.is_some_and(|n| n > 0)
                }
                "resumeHostOnlyAtConfirmedSafeBoundary" => {
                    next == "resumeAtConfirmedSafeBoundary" && confirmed && revision.is_none()
                }
                "waitingForRecovery" => {
                    next == "waitingForRecovery"
                        && ["confirmed", "outcomeUnknown"].contains(&certainty)
                }
                "finalizeConfirmedFailure" | "finalizeLanePostflightRecovered" => {
                    next == "finalizing" && confirmed && revision.is_some_and(|n| n > 0)
                }
                "finalizeHostOnlyConfirmedFailure" => {
                    next == "finalizing" && confirmed && revision.is_none()
                }
                "noAction" => next == "waitingForRecovery",
                _ => false,
            })?;
        }
        "abandonIntent" => {
            keys(
                p,
                &[
                    "userConfirmationId",
                    "lastConfirmedStep",
                    "outcomeCertainty",
                    "managedProcessState",
                    "deviceHazards",
                ],
                &[],
            )?;
            string(p, "userConfirmationId")?;
            nullable_string(p, "lastConfirmedStep", true)?;
            choice(p, "outcomeCertainty", &["confirmed", "outcomeUnknown"])?;
            choice(
                p,
                "managedProcessState",
                &[
                    "notRunning",
                    "runningInterruptible",
                    "criticalAwaitingSafeBoundary",
                    "unknown",
                ],
            )?;
            strings(p, "deviceHazards", 0)?;
        }
        "abandonOutcome" => {
            keys(
                p,
                &[
                    "correlatesToAbandonIntentEventId",
                    "result",
                    "releaseAuthorized",
                    "unresolvedHazards",
                ],
                &[],
            )?;
            string(p, "correlatesToAbandonIntentEventId")?;
            let result = choice(p, "result", &["archivedInterrupted", "deferred", "failed"])?;
            require(p["releaseAuthorized"].as_bool() == Some(result == "archivedInterrupted"))?;
            strings(p, "unresolvedHazards", 0)?;
        }
        "warning" | "error" => {
            keys(p, &["code", "message", "details"], &[])?;
            string(p, "code")?;
            string(p, "message")?;
            object(&p["details"])?;
        }
        "finalized" => {
            keys(
                p,
                &["terminalStatus", "manifestSha256", "outcomeCertainty"],
                &[],
            )?;
            let status = choice(
                p,
                "terminalStatus",
                &[
                    "planned",
                    "succeeded",
                    "recovered",
                    "failed",
                    "cancelled",
                    "interrupted",
                ],
            )?;
            require(lower_hash(text(p, "manifestSha256")?))?;
            let certainty = text(p, "outcomeCertainty")?;
            require(if status == "interrupted" {
                ["confirmed", "outcomeUnknown", "mixed"].contains(&certainty)
            } else {
                certainty == "confirmed"
            })?;
        }
        _ => return Err(ManifestError::Invalid),
    }
    Ok(())
}
