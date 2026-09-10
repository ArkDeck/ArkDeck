//! Structural and relational validation of historical Session steps. These
//! records are never converted into dispatch requests or Runtime authority.
use super::*;
use std::collections::{BTreeMap, BTreeSet};

fn signed(row: &Object, key: &str) -> Result<Option<i64>> {
    match row.get(key) {
        Some(Value::Null) => Ok(None),
        Some(v) => v.as_i64().map(Some).ok_or(ManifestError::Invalid),
        None => Err(ManifestError::Invalid),
    }
}

fn typed(row: &Object) -> Result<()> {
    require(identifier(text(row, "id")?))?;
    let args = object(&row["arguments"])?;
    let policy = crate::session_step_arguments::validate(text(row, "kind")?, args)?;
    let effect = choice(
        row,
        "effect",
        &["hostOnly", "readOnly", "deviceMutation", "destructive"],
    )?;
    let cancellation = choice(
        row,
        "cancellation",
        &["immediate", "atSafeBoundary", "criticalNonInterruptible"],
    )?;
    let binding = choice(row, "bindingRequirement", &["none", "confirmedDevice"])?;
    require(
        ["hostOnly", "readOnly", "deviceMutation", "destructive"]
            .iter()
            .position(|v| *v == effect)
            .is_some_and(|rank| rank >= policy.effect),
    )?;
    require(
        ["immediate", "atSafeBoundary", "criticalNonInterruptible"]
            .iter()
            .position(|v| *v == cancellation)
            .is_some_and(|rank| rank >= policy.cancellation),
    )?;
    let rank = usize::from(binding == "confirmedDevice");
    require(if policy.exact_binding {
        rank == policy.binding
    } else {
        rank >= policy.binding
    })?;
    // Use the frozen Foundation document encoding domain, not CLI JCS.
    let bytes =
        crate::session_json::encode(&row["arguments"]).map_err(|_| ManifestError::Invalid)?;
    require(
        text(row, "argumentsHash")?.to_ascii_lowercase() == arkdeck_contract::sha256_hex(&bytes),
    )
}

fn descriptor(value: &Value) -> Result<&Object> {
    let row = object(value)?;
    keys(
        row,
        &[
            "id",
            "kind",
            "effect",
            "cancellation",
            "bindingRequirement",
            "trigger",
            "arguments",
            "argumentsHash",
        ],
        &[],
    )?;
    choice(
        row,
        "kind",
        &[
            "stopRemoteCapture",
            "restoreParameter",
            "cleanupOwnedRemotePath",
            "removePortForward",
            "stopApplication",
            "uninstallPackage",
        ],
    )?;
    choice(
        row,
        "trigger",
        &["onSuccess", "onFailure", "onCancel", "onAnyTerminal"],
    )?;
    typed(row)?;
    Ok(row)
}
fn failure(value: &Value) -> Result<()> {
    if value.is_null() {
        return Ok(());
    }
    let row = object(value)?;
    keys(row, &["stage", "code", "summary"], &[])?;
    nonempty(row, "stage")?;
    nonempty(row, "summary")?;
    require(identifier(text(row, "code")?))
}
fn execution(row: &Object) -> Result<()> {
    keys(
        row,
        &[
            "id",
            "kind",
            "effect",
            "cancellation",
            "bindingRequirement",
            "arguments",
            "argumentsHash",
            "compensationDescriptors",
            "sourceStepId",
            "compensationTrigger",
            "disposition",
            "outcomeCertainty",
            "bindingRevision",
            "semanticResult",
        ],
        &["exitCode", "durationNanoseconds"],
    )?;
    typed(row)?;
    for d in array(row, "compensationDescriptors")? {
        descriptor(d)?;
    }
    let revision = signed(row, "bindingRevision")?;
    require(if text(row, "bindingRequirement")? == "none" {
        revision.is_none()
    } else {
        revision.is_some_and(|n| n >= 1)
    })?;
    let source = nullable_text(row, "sourceStepId")?;
    let trigger = nullable_text(row, "compensationTrigger")?;
    require(source.is_none() == trigger.is_none())?;
    if let Some(source) = source {
        require(
            identifier(&source)
                && trigger.as_deref().is_some_and(|t| {
                    ["onSuccess", "onFailure", "onCancel", "onAnyTerminal"].contains(&t)
                }),
        )?;
    }
    let disposition = choice(
        row,
        "disposition",
        &[
            "executed",
            "notExecuted(planned)",
            "skipped",
            "outcomeUnknown",
        ],
    )?;
    let certainty = choice(
        row,
        "outcomeCertainty",
        &["confirmed", "outcomeUnknown", "notApplicable"],
    )?;
    let result = choice(
        row,
        "semanticResult",
        &["succeeded", "failed", "notRun", "unknown"],
    )?;
    require(match disposition {
        "executed" => certainty == "confirmed" && ["succeeded", "failed"].contains(&result),
        "outcomeUnknown" => certainty == "outcomeUnknown" && result == "unknown",
        _ => certainty == "notApplicable" && result == "notRun",
    })?;
    if row.contains_key("durationNanoseconds") {
        require(signed(row, "durationNanoseconds")?.is_none_or(|n| n >= 0))?;
    }
    if row.contains_key("exitCode") {
        signed(row, "exitCode")?;
    }
    Ok(())
}

// JSONValue equality uses Swift String canonical equivalence in relationship
// checks. The digest above still compares the original canonical bytes.
fn equal(a: &Value, b: &Value) -> Result<bool> {
    Ok(match (a, b) {
        (Value::String(a), Value::String(b)) => {
            arkdeck_platform::host_canonical_text(a).ok_or(ManifestError::Unsupported)?
                == arkdeck_platform::host_canonical_text(b).ok_or(ManifestError::Unsupported)?
        }
        (Value::Array(a), Value::Array(b)) => {
            if a.len() != b.len() {
                return Ok(false);
            }
            for (a, b) in a.iter().zip(b) {
                if !equal(a, b)? {
                    return Ok(false);
                }
            }
            true
        }
        (Value::Object(a), Value::Object(b)) => {
            if a.len() != b.len() {
                return Ok(false);
            }
            for (key, a) in a {
                let Some(b) = b.get(key) else {
                    return Ok(false);
                };
                if !equal(a, b)? {
                    return Ok(false);
                }
            }
            true
        }
        _ => a == b,
    })
}

pub(super) fn validate(doc: &Object, host: bool) -> Result<()> {
    let mode = text(doc, "executionMode")?;
    let status = text(doc, "status")?;
    let standard = text(doc, "executionAuthority")? == "standardAgent";
    // The parent has checked the closed historical audit. This flag selects
    // Swift's decoding branch only; it never grants Runtime authority.
    let consumed = doc
        .get("runtimeAuthority")
        .and_then(Value::as_object)
        .and_then(|a| a.get("kind"))
        .and_then(Value::as_str)
        == Some("runtimeCapability");
    let provider = object(&doc["toolchain"])?
        .get("providerIdentity")
        .and_then(Value::as_str);
    let mut steps = BTreeMap::new();
    let mut descriptors = BTreeMap::new();
    let revisions: BTreeSet<_> = array(doc, "bindingHistory")?
        .iter()
        .map(|v| object(v).and_then(|r| r["revision"].as_i64().ok_or(ManifestError::Invalid)))
        .collect::<Result<_>>()?;
    for value in array(doc, "steps")? {
        let row = object(value)?;
        execution(row)?;
        let id = text(row, "id")?;
        require(steps.insert(id, row).is_none())?;
        if let Some(revision) = signed(row, "bindingRevision")? {
            require(revisions.contains(&revision))?;
        }
        let effect = text(row, "effect")?;
        if host {
            require(effect == "hostOnly" && text(row, "bindingRequirement")? == "none")?;
        }
        let disposition = text(row, "disposition")?;
        let result = text(row, "semanticResult")?;
        if (((standard && !consumed) || mode == "simulated") && effect == "destructive")
            || (mode == "planOnly" && ["deviceMutation", "destructive"].contains(&effect))
        {
            require(["notExecuted(planned)", "skipped"].contains(&disposition))?;
        }
        if ["planned", "succeeded", "failed", "cancelled"].contains(&status) {
            require(disposition != "outcomeUnknown")?;
        }
        if status == "succeeded" {
            require(!["failed", "unknown"].contains(&result))?;
            if standard && !consumed && mode == "execute" {
                require(effect != "destructive")?;
            }
        }
        for value in array(row, "compensationDescriptors")? {
            let d = object(value)?;
            require(descriptors.insert(text(d, "id")?, (id, value)).is_none())?;
        }
    }
    for row in steps.values() {
        if let Some(source) = nullable_text(row, "sourceStepId")? {
            require(steps.contains_key(source.as_str()))?;
            let (declared_source, value) = descriptors
                .get(text(row, "id")?)
                .ok_or(ManifestError::Invalid)?;
            require(source == *declared_source)?;
            let d = object(value)?;
            for key in [
                "id",
                "kind",
                "effect",
                "cancellation",
                "bindingRequirement",
                "arguments",
                "argumentsHash",
            ] {
                require(equal(&row[key], &d[key])?)?;
            }
            require(equal(&row["compensationTrigger"], &d["trigger"])?)?;
        }
        let arguments = object(&row["arguments"])?;
        if let Some(value) = arguments.get("confirmationId").filter(|v| !v.is_null()) {
            let id = value.as_str().ok_or(ManifestError::Invalid)?;
            if consumed
                && ((provider == Some("arkforge")
                    && text(row, "kind")? == "flashPartition"
                    && id == "runtimeE2Admission")
                    || (provider == Some("hdc")
                        && text(row, "kind")? == "runApprovedRemoteMutation"
                        && id == "runtime-capability-admission"))
            {
                continue;
            }
            let mut found = false;
            for c in array(doc, "confirmations")? {
                let c = object(c)?;
                if text(c, "confirmationId")? == id {
                    found = array(c, "relatedStepIds")?
                        .iter()
                        .any(|v| v.as_str() == row["id"].as_str());
                }
            }
            require(found)?;
        }
    }
    let mut compensation_ids = BTreeSet::new();
    for value in array(doc, "compensations")? {
        let row = object(value)?;
        keys(
            row,
            &[
                "descriptor",
                "sourceStepId",
                "disposition",
                "outcomeCertainty",
                "result",
                "failure",
                "journalEventIds",
            ],
            &[],
        )?;
        let d = descriptor(&row["descriptor"])?;
        let id = text(d, "id")?;
        require(compensation_ids.insert(id))?;
        let source = text(row, "sourceStepId")?;
        require(identifier(source) && steps.contains_key(source))?;
        let (declared_source, declared) = descriptors.get(id).ok_or(ManifestError::Invalid)?;
        require(source == *declared_source && equal(declared, &row["descriptor"])?)?;
        for event in array(row, "journalEventIds")? {
            require(event.as_str().is_some_and(identifier))?;
        }
        failure(&row["failure"])?;
        let disposition = choice(
            row,
            "disposition",
            &["executed", "notRun", "outcomeUnknown"],
        )?;
        let certainty = choice(
            row,
            "outcomeCertainty",
            &["confirmed", "outcomeUnknown", "notApplicable"],
        )?;
        let result = choice(row, "result", &["succeeded", "failed", "notRun", "unknown"])?;
        require(match disposition {
            "executed" => {
                certainty == "confirmed"
                    && ((result == "succeeded" && row["failure"].is_null())
                        || (result == "failed" && !row["failure"].is_null()))
            }
            "notRun" => {
                certainty == "notApplicable" && result == "notRun" && row["failure"].is_null()
            }
            _ => certainty == "outcomeUnknown" && result == "unknown",
        })?;
        if standard && !consumed && text(d, "effect")? == "destructive" {
            require(disposition == "notRun")?;
        }
        if status == "succeeded" {
            require(!["failed", "unknown"].contains(&result))?;
        }
    }
    recovery(&doc["recovery"], &steps, &descriptors)?;
    Ok(())
}

fn recovery(
    value: &Value,
    steps: &BTreeMap<&str, &Object>,
    descriptors: &BTreeMap<&str, (&str, &Value)>,
) -> Result<()> {
    if value.is_null() {
        return Ok(());
    }
    let row = object(value)?;
    keys(
        row,
        &[
            "needsAttention",
            "interruptedReason",
            "deviceHazards",
            "abandonAuditEventIds",
            "lastConfirmedStepId",
            "lastDeviceMode",
            "managedHostProcessState",
            "recoveryGuide",
            "unexecutedCompensations",
            "userConfirmation",
            "recoveryOfSessionId",
            "recoveryOfJobId",
        ],
        &[],
    )?;
    require(row["needsAttention"].is_boolean())?;
    require(nullable_text(row, "interruptedReason")?.is_none_or(|s| !s.is_empty()))?;
    for key in [
        "lastConfirmedStepId",
        "recoveryOfSessionId",
        "recoveryOfJobId",
    ] {
        if let Some(id) = nullable_text(row, key)? {
            require(identifier(&id))?;
            if key == "lastConfirmedStepId" {
                require(steps.contains_key(id.as_str()))?;
            }
        }
    }
    let mut event_ids = BTreeSet::new();
    for event in array(row, "abandonAuditEventIds")? {
        let id = event.as_str().ok_or(ManifestError::Invalid)?;
        require(identifier(id) && event_ids.insert(id))?;
    }
    for value in array(row, "deviceHazards")? {
        let hazard = object(value)?;
        keys(
            hazard,
            &["code", "summary", "severity", "outcomeCertainty"],
            &[],
        )?;
        require(identifier(text(hazard, "code")?))?;
        nonempty(hazard, "summary")?;
        choice(
            hazard,
            "severity",
            &["warning", "blocking", "possibleBrick"],
        )?;
        choice(hazard, "outcomeCertainty", &["confirmed", "outcomeUnknown"])?;
    }
    choice(
        row,
        "managedHostProcessState",
        &[
            "notStarted",
            "notRunning",
            "stoppedAtSafeBoundary",
            "stillRunningUnknown",
            "notApplicable",
        ],
    )?;
    let mode = object(&row["lastDeviceMode"])?;
    match text(mode, "state")? {
        "unknown" => keys(mode, &["state"], &[])?,
        "known" => {
            keys(mode, &["state", "value", "evidence"], &[])?;
            nonempty(mode, "value")?;
            nonempty(mode, "evidence")?;
        }
        _ => return Err(ManifestError::Invalid),
    }
    let guide = object(&row["recoveryGuide"])?;
    keys(
        guide,
        &[
            "providerIdentity",
            "automaticRecoveryAvailable",
            "summary",
            "steps",
        ],
        &[],
    )?;
    nonempty(guide, "providerIdentity")?;
    nonempty(guide, "summary")?;
    require(guide["automaticRecoveryAvailable"].is_boolean())?;
    let guidance = array(guide, "steps")?;
    require(
        !guidance.is_empty()
            && guidance
                .iter()
                .all(|v| v.as_str().is_some_and(|s| !s.is_empty())),
    )?;
    let confirmation = &row["userConfirmation"];
    require(event_ids.is_empty() || !confirmation.is_null())?;
    if !confirmation.is_null() {
        let confirmation = object(confirmation)?;
        keys(
            confirmation,
            &["confirmationId", "actor", "decision", "confirmedAt"],
            &[],
        )?;
        require(
            identifier(text(confirmation, "confirmationId")?)
                && text(confirmation, "actor")? == "user"
                && text(confirmation, "decision")? == "archiveInterrupted",
        )?;
        timestamp(confirmation, "confirmedAt")?;
    }
    for value in array(row, "unexecutedCompensations")? {
        let d = descriptor(value)?;
        let (_, declared) = descriptors
            .get(text(d, "id")?)
            .ok_or(ManifestError::Invalid)?;
        require(equal(value, declared)?)?;
    }
    Ok(())
}
