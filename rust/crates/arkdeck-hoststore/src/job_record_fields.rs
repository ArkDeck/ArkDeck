//! Frozen nested Job snapshot shapes, decoded as historical data only.
//! These checks cannot authorize a provider action or establish fresh facts.
use super::job_record::{closed, unreadable};
use arkdeck_contract::WireError;
use serde_json::{Value, json};

type Result<T = ()> = std::result::Result<T, WireError>;
type Validator = fn(&Value) -> Result;

fn text(v: &Value) -> Result {
    v.as_str().map(|_| ()).ok_or_else(|| unreadable(()))
}
fn integer(v: &Value) -> Result {
    v.as_i64().map(|_| ()).ok_or_else(|| unreadable(()))
}
fn strings(v: &Value) -> Result {
    array(v, text)
}
fn array(v: &Value, validate: Validator) -> Result {
    for item in v.as_array().ok_or_else(|| unreadable(()))? {
        validate(item)?;
    }
    Ok(())
}
fn choice(v: &Value, choices: &[&str]) -> Result {
    if choices.iter().any(|s| v == s) {
        Ok(())
    } else {
        Err(unreadable(()))
    }
}
fn shape(v: &Value, required: &[(&str, Validator)], optional: &[(&str, Validator)]) -> Result {
    let row = closed(
        v,
        &required.iter().map(|x| x.0).collect::<Vec<_>>(),
        &optional.iter().map(|x| x.0).collect::<Vec<_>>(),
    )?;
    for (key, validate) in required.iter().chain(optional) {
        if let Some(value) = row.get(*key) {
            validate(value)?;
        }
    }
    Ok(())
}

pub(super) fn admission(v: &Value) -> Result {
    shape(
        v,
        &[("kind", text), ("reference", text), ("admittedAtUTC", text)],
        &[
            ("validUntilUTC", text),
            ("consumptionFingerprintSHA256", text),
            ("runtimeCapabilityCorrelation", correlation),
            ("completeOverwriteRecovery", recovery),
            ("recoveryProviderExecutableSHA256", text),
        ],
    )?;
    choice(&v["kind"], &["defaultReadOnlyPolicy", "runtimeCapability"])
}
fn correlation(v: &Value) -> Result {
    shape(
        v,
        &[
            ("reservationID", text),
            ("useOrdinal", integer),
            ("planDigestSHA256", text),
            ("stepSetDigestSHA256", text),
            ("targetBindingDigestSHA256", text),
        ],
        &[("artifactSHA256", text)],
    )
}
fn recovery(v: &Value) -> Result {
    shape(
        v,
        &[
            ("coveredIntents", |v| array(v, covered_intent)),
            ("uncertainEffectSetSHA256", text),
            ("coverageContractVersion", text),
            ("coveredEffectSetSHA256", text),
            ("profileReference", text),
            ("destructiveEpochOrdinal", integer),
        ],
        &[],
    )
}
fn covered_intent(v: &Value) -> Result {
    shape(
        v,
        &[
            ("jobID", text),
            ("intentEventID", text),
            ("operationReference", text),
            ("profileReference", text),
            ("observedAtUTC", text),
            ("possibleEffects", strings),
        ],
        &[],
    )
}
pub(super) fn persisted_action(v: &Value) -> Result {
    // PersistedTypedProviderAction stores an arbitrary JSONValue argument map.
    // Restoring an executable action is a separate, as-yet-unmigrated boundary.
    shape(
        v,
        &[
            ("kind", text),
            ("arguments", |v| {
                v.as_object().map(|_| ()).ok_or_else(|| unreadable(()))
            }),
        ],
        &[],
    )
}
pub(super) fn operation_failure(v: &Value) -> Result {
    shape(
        v,
        &[
            ("schemaVersion", text),
            ("code", text),
            ("category", text),
            ("retryability", text),
            ("recovery", text),
        ],
        &[],
    )?;
    choice(&v["schemaVersion"], &["1.0.0"])?;
    choice(
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
    )?;
    choice(
        &v["category"],
        &[
            "execution",
            "externalTool",
            "storage",
            "cancelled",
            "unknownOutcome",
            "runtime",
        ],
    )?;
    choice(
        &v["retryability"],
        &["notAutomatic", "runtimeDecisionRequired"],
    )?;
    choice(
        &v["recovery"],
        &[
            "none",
            "inspectJob",
            "awaitRuntimeReconciliation",
            "submitNewTypedRequestAfterRuntimeProof",
        ],
    )
}
fn evidence_step(v: &Value) -> Result {
    shape(
        v,
        &[("stepID", text), ("stepKind", text), ("outcomeAtUTC", text)],
        &[("carriedFromUTC", text)],
    )
}
pub(super) fn preflight(v: &Value) -> Result {
    shape(
        v,
        &[
            ("targetID", text),
            ("bindingRevision", integer),
            ("stableIdentitySHA256", text),
            ("providerID", text),
            ("toolVersion", text),
            ("toolSHA256", text),
            ("steps", |v| array(v, evidence_step)),
        ],
        &[
            ("transport", text),
            ("confirmedAtUTC", text),
            ("model", text),
            ("firmware", text),
        ],
    )
}
pub(super) fn observation(v: &Value) -> Result {
    shape(
        v,
        &[
            ("providerID", text),
            ("toolVersion", text),
            ("toolSHA256", text),
            ("confirmationMethod", text),
            ("preflightSteps", |v| array(v, evidence_step)),
        ],
        &[
            ("targetID", text),
            ("bindingRevision", integer),
            ("stableIdentitySHA256", text),
            ("model", text),
            ("firmware", text),
            ("transport", text),
            ("confirmedAtUTC", text),
        ],
    )
}
pub(super) fn trace_probe(v: &Value) -> Result {
    shape(
        v,
        &[
            ("targetID", text),
            ("bindingRevision", integer),
            ("adapterDisposition", text),
            ("supportedTags", strings),
            ("tools", |v| array(v, trace_tool)),
            ("parameters", |v| array(v, trace_parameter)),
        ],
        &[
            ("tool", text),
            ("family", text),
            ("rawHelp", text),
            ("rawHelpSHA256", text),
        ],
    )
}
fn trace_tool(v: &Value) -> Result {
    shape(
        v,
        &[("tool", text), ("disposition", text)],
        &[("family", text), ("rawHelpSHA256", text), ("detail", text)],
    )?;
    choice(
        &v["disposition"],
        &[
            "captureEligible",
            "probeOnly",
            "unrecognized",
            "probeFailed",
        ],
    )
}
fn trace_parameter(v: &Value) -> Result {
    shape(
        v,
        &[("name", text), ("state", text)],
        &[("value", text), ("detail", text)],
    )?;
    choice(&v["state"], &["missing", "unreadable", "value"])
}
fn publication_root(v: &Value) -> Result {
    shape(
        v,
        &[
            ("path", text),
            ("device", text),
            ("inode", text),
            ("volumeIdentity", text),
        ],
        &[],
    )
}
fn publication_identity(v: &Value) -> Result {
    shape(v, &[("device", text), ("inode", text)], &[])
}
fn publication_claim(v: &Value) -> Result {
    shape(
        v,
        &[
            ("volumeIdentity", text),
            ("claimID", text),
            ("admissionGeneration", text),
            ("writerClass", text),
            ("metadataHeadroomBytes", text),
            ("finalizationHeadroomBytes", text),
            ("remainingGrowthBytes", text),
        ],
        &[],
    )
}
fn publication_seal(v: &Value) -> Result {
    shape(
        v,
        &[
            ("sha256", text),
            ("byteCount", text),
            ("lastSequence", integer),
        ],
        &[],
    )
}
fn publication_proposal(v: &Value) -> Result {
    shape(
        v,
        &[
            ("manifestSHA256", text),
            ("manifestByteCount", text),
            ("terminalStatus", text),
            ("outcomeCertainty", text),
            ("completedAtUTC", text),
        ],
        &[],
    )
}
fn publication_receipt(v: &Value) -> Result {
    shape(
        v,
        &[
            ("manifestSHA256", text),
            ("catalogGeneration", text),
            ("publishedAtUTC", text),
        ],
        &[],
    )
}
fn publication_failure(v: &Value) -> Result {
    shape(
        v,
        &[("code", text), ("certainty", text), ("detail", text)],
        &[],
    )
}
pub(super) fn publication(v: &Value) -> Result {
    shape(
        v,
        &[
            ("sessionID", text),
            ("catalogDigest", text),
            ("policyGeneration", text),
            ("root", publication_root),
            ("relativeSessionPath", text),
            ("claims", |v| array(v, publication_claim)),
            ("phase", text),
        ],
        &[
            ("sessionRootIdentity", publication_identity),
            ("checkpointSeal", publication_seal),
            ("proposal", publication_proposal),
            ("journalSeal", publication_seal),
            ("receipt", publication_receipt),
            ("failure", publication_failure),
        ],
    )?;
    choice(
        &v["phase"],
        &[
            "awaitingStorage",
            "prepared",
            "sealed",
            "manifestPublished",
            "catalogPublished",
        ],
    )
}

pub(super) fn publication_fact(marker: Option<&Value>) -> Value {
    let fact = |state: &str, reason: &str| json!({"state":state,"manifestSha256":null,"catalogGeneration":null,"reasonCode":reason});
    let Some(marker) = marker else {
        return fact("unavailable", "noCurrentPublicationRecord");
    };
    // Match RuntimeSessionPublicationRecord.fact: receipt precedes failure;
    // malformed receipt never degrades to an invented confirmed failure.
    if let Some(receipt) = marker.get("receipt") {
        let hash = receipt["manifestSHA256"].as_str().unwrap_or("");
        let generation = receipt["catalogGeneration"].as_str().unwrap_or("");
        if super::job_record::digest(hash)
            && generation
                .parse::<u64>()
                .is_ok_and(|n| n.to_string() == generation)
        {
            return json!({"state":"published","manifestSha256":hash,"catalogGeneration":generation,"reasonCode":null});
        }
        return fact("outcomeUnknown", "publicationUncertain");
    }
    if let Some(failure) = marker.get("failure") {
        if failure["certainty"] == "confirmed"
            && [
                "storageUnavailable",
                "sourceIntegrityFailed",
                "identityChanged",
                "contractViolation",
            ]
            .iter()
            .any(|s| failure["code"] == *s)
        {
            return fact("failed", failure["code"].as_str().unwrap_or(""));
        }
        return fact("outcomeUnknown", "publicationUncertain");
    }
    fact(
        "pending",
        if marker["phase"] == "awaitingStorage" {
            "waitingForStorage"
        } else {
            "jobNotTerminal"
        },
    )
}
