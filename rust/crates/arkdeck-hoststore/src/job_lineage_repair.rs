//! Swift `RuntimeJobEngine.recordCapabilityOutcome` and the repairs of a
//! capability outcome a crash lost (`repairTerminalSafeToReflashLineageIfNeeded`,
//! `repairTerminalCancelledLineageIfNeeded`,
//! `repairProvablyTerminalCapabilityOutcomeGaps`): ADR-0009 decision 4 as the
//! maintainer ruled on 2026-09-19 (design §L.1 item 13), its carriers ported
//! unchanged.
//!
//! A terminal Job record becomes durable before the independently durable
//! outcome of the capability use it ran under, so a crash between the two
//! leaves the Job complete and its use `pending` or `outcomeUnknown`. An
//! existing proof is never discarded: a failed Job whose journal holds the
//! reconciled `confirmedNotExecuted` step outcome of its mutation, with no
//! mutation intent after it and only the confirmed failure decision after it,
//! settles its use `safeToReflash`; a cancelled Job whose use is still
//! `pending` settles it `confirmed`. Nothing is dispatched, and nothing but
//! the capability ledger is written. A record that is missing, unreadable,
//! not terminal, unknown or differently bound is left as it is, and the
//! lineage gate refuses the next mutation over it.
//!
//! A debug HAP's repair also reads its failure finalization and cleanup debt
//! (`RuntimeDebugHAPFailureFinalization`), which this Runtime does not port
//! yet: its use is left as it is, so the lineage stays blocked (fail closed).
use crate::artifact_read_owner::swift_string;
use crate::capability_store::{CapabilityStore, UseOutcome};
use crate::job_journal_writer::inspect_journal;
use crate::job_owner::JobStore;
use crate::job_record::JobRecord;
use crate::swift_decoding::same_text;
use serde_json::Value;
use std::collections::BTreeSet;

/// Swift `RuntimeJobEngine.confirmedNotExecutedSemanticCode`.
pub(crate) const CONFIRMED_NOT_EXECUTED: &str = "confirmedNotExecuted";
const HAP: &str = "debug.hap@1";

/// Why a repair or an outcome could not be completed, as Swift's handlers
/// tell the two apart.
#[derive(Debug)]
pub(crate) enum RepairError {
    /// A `RuntimeJobEngineError`, interpolated: `job.reconcile` answers it
    /// `rejected`.
    Engine(String),
    /// Any other error, interpolated: answered `internalError`.
    Other(String),
}

/// Whether the Job was admitted under a runtime capability, whose use its
/// outcome settles.
pub(crate) fn runtime_capability(record: &JobRecord) -> bool {
    record
        .admission_evidence()
        .is_some_and(|evidence| evidence["kind"] == "runtimeCapability")
}

/// Whether reconciling this terminal Job may write its use's outcome: the two
/// lineage repairs' own guards before either reads anything.
pub(crate) fn repairs_lineage(record: &JobRecord) -> bool {
    !record.outcome_unknown()
        && matches!(record.state.as_str(), "failed" | "cancelled")
        && runtime_capability(record)
}

/// Swift `recordCapabilityOutcome`: the use the Job's runtime capability
/// admitted it under settled with `outcome` and the Job's `state`. A Job
/// admitted any other way settles nothing. Without a store nothing can be
/// settled, and the call fails closed.
pub(crate) fn record_capability_outcome(
    record: &JobRecord,
    capabilities: Option<&CapabilityStore>,
    outcome: UseOutcome,
    state: &str,
    now: fn() -> Option<String>,
) -> Result<(), RepairError> {
    let Some(evidence) = record
        .admission_evidence()
        .filter(|evidence| evidence["kind"] == "runtimeCapability")
    else {
        return Ok(());
    };
    let lineage = |detail: String| {
        RepairError::Engine(format!(
            "internalFailure({})",
            swift_string(&format!(
                "authorization lineage could not become durable: {detail}"
            ))
        ))
    };
    let store =
        capabilities.ok_or_else(|| lineage("no Runtime capability store is composed".into()))?;
    let at = now().ok_or_else(|| {
        RepairError::Engine(format!(
            "internalFailure({})",
            swift_string("the Runtime clock is unavailable")
        ))
    })?;
    store
        .record_outcome(
            evidence["reference"].as_str().unwrap_or_default(),
            record.request["idempotencyKey"]
                .as_str()
                .unwrap_or_default(),
            &record.job_id,
            outcome,
            state,
            &at,
        )
        .map_err(|error| lineage(error.swift()))
}

/// Every complete record of the Job's journal, in order (Swift
/// `DurableJournalRecovery.inspect(url:).events`).
fn journal_events(jobs: &JobStore, job_id: &str) -> Result<Vec<Value>, RepairError> {
    let bytes = jobs
        .journal_bytes(job_id)
        .map_err(|error| RepairError::Other(format!("{error}")))?;
    let durable = bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |last| last + 1);
    bytes[..durable]
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
        .map(|line| {
            serde_json::from_slice(line).map_err(|_| {
                RepairError::Other(
                    "sequenceViolation(\"the Job Journal cannot be replayed\")".into(),
                )
            })
        })
        .collect()
}

/// Swift `(event.externalEffect ?? .destructive) >= .deviceMutation`: an
/// intent whose effect cannot be read counts as a mutation.
fn mutating_intent(event: &Value) -> bool {
    let effect = match event["kind"].as_str() {
        Some("stepIntent") => &event["payload"]["step"]["effect"],
        Some("compensationIntent") => &event["payload"]["descriptor"]["effect"],
        _ => return false,
    };
    !matches!(effect.as_str(), Some("hostOnly" | "readOnly"))
}

fn sequence(event: &Value) -> i64 {
    event["sequence"].as_i64().unwrap_or(i64::MIN)
}

/// Swift `repairTerminalSafeToReflashLineageIfNeeded`: a failed Job whose
/// journal proves its mutation was confirmed not executed settles its use
/// `safeToReflash`, without dispatching anything.
pub(crate) fn repair_safe_to_reflash(
    jobs: &JobStore,
    capabilities: Option<&CapabilityStore>,
    record: &JobRecord,
    now: fn() -> Option<String>,
) -> Result<(), RepairError> {
    if record.outcome_unknown() || record.state != "failed" || !runtime_capability(record) {
        return Ok(());
    }
    let directory = jobs
        .job_directory(&record.job_id)
        .map_err(|error| RepairError::Other(format!("{error:?}")))?;
    let facts =
        inspect_journal(&directory).map_err(|error| RepairError::Other(format!("{error}")))?;
    // A debug HAP's own repair is not ported: its use is left as it is.
    if record.operation() == HAP {
        return Ok(());
    }
    let events = journal_events(jobs, &record.job_id)?;
    if facts.current_state.as_deref() != Some("failed") {
        return Ok(());
    }
    let Some(proof) = events.iter().rev().find(|event| {
        event["kind"] == "stepOutcome"
            && event["payload"]["semanticCode"] == CONFIRMED_NOT_EXECUTED
            && event["payload"]["outcomeCertainty"] == "confirmed"
    }) else {
        return Ok(());
    };
    let Some(intent) = proof["payload"]["correlatesToIntentEventId"].as_str() else {
        return Ok(());
    };
    let proven = sequence(proof);
    let mutation = events.iter().any(|event| {
        event["kind"] == "stepIntent" && event["eventId"] == intent && mutating_intent(event)
    });
    let later = events
        .iter()
        .any(|event| sequence(event) > proven && mutating_intent(event));
    if !mutation || later {
        return Ok(());
    }
    if let Some(decision) = events
        .iter()
        .rev()
        .find(|event| event["kind"] == "reconcileOutcome" && sequence(event) > proven)
    {
        let payload = &decision["payload"];
        if facts.last_reconcile_outcome_certainty.as_deref() != Some("confirmed")
            || payload["result"] != "finalizeConfirmedFailure"
            || payload["nextState"] != "finalizing"
            || payload["safeBoundaryConfirmed"] != true
        {
            return Ok(());
        }
    }
    record_capability_outcome(
        record,
        capabilities,
        UseOutcome::SafeToReflash,
        "failed",
        now,
    )
}

/// Swift `repairTerminalCancelledLineageIfNeeded`: a cancelled Job whose use
/// is still `pending` settles it `confirmed`; a drained cancellation is one
/// the engine proved did not dispatch.
pub(crate) fn repair_cancelled(
    capabilities: Option<&CapabilityStore>,
    record: &JobRecord,
    now: fn() -> Option<String>,
) -> Result<(), RepairError> {
    if record.outcome_unknown() || record.state != "cancelled" || !runtime_capability(record) {
        return Ok(());
    }
    let Some(store) = capabilities else {
        return Err(RepairError::Other(
            "no Runtime capability store is composed".into(),
        ));
    };
    let reference = record
        .admission_evidence()
        .and_then(|evidence| evidence["reference"].as_str())
        .unwrap_or_default();
    let pending = store
        .lineage()
        .map_err(|error| RepairError::Other(error.swift()))?
        .iter()
        .any(|use_| {
            same_text(&use_.capability, reference)
                && same_text(&use_.job, &record.job_id)
                && use_.outcome == UseOutcome::Pending
        });
    if !pending {
        return Ok(());
    }
    record_capability_outcome(
        record,
        capabilities,
        UseOutcome::Confirmed,
        "cancelled",
        now,
    )
}

/// Swift `repairProvablyTerminalCapabilityOutcomeGaps`, before a mutation's
/// plan is materialized: every Job holding a `pending` or `outcomeUnknown`
/// use at this binding revision, in identity order, whose record names this
/// Target at this revision, is repaired as a reconcile repairs it. A record
/// that cannot be read is skipped.
pub(crate) fn repair_outcome_gaps(
    jobs: &JobStore,
    capabilities: &CapabilityStore,
    target_id: &str,
    binding_revision: i64,
    now: fn() -> Option<String>,
) -> Result<(), RepairError> {
    let unresolved: BTreeSet<String> = capabilities
        .lineage()
        .map_err(|error| RepairError::Other(error.swift()))?
        .into_iter()
        .filter(|use_| {
            use_.binding_revision == Some(binding_revision)
                && matches!(
                    use_.outcome,
                    UseOutcome::Pending | UseOutcome::OutcomeUnknown
                )
        })
        .map(|use_| use_.job)
        .collect();
    for job in unresolved {
        let Ok(record) = jobs.read_snapshot(&job) else {
            continue;
        };
        let target = &record.request["target"];
        if target["targetId"] != target_id
            || target["expectedBindingRevision"].as_i64() != Some(binding_revision)
        {
            continue;
        }
        repair_safe_to_reflash(jobs, Some(capabilities), &record, now)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn an_intent_whose_effect_cannot_be_read_counts_as_a_mutation() {
        let intent = |kind: &str, key: &str, effect: Value| json!({"kind": kind, "payload": {key: {"effect": effect}}});
        for (event, mutates) in [
            (intent("stepIntent", "step", json!("readOnly")), false),
            (intent("stepIntent", "step", json!("hostOnly")), false),
            (intent("stepIntent", "step", json!("deviceMutation")), true),
            (intent("stepIntent", "step", json!("destructive")), true),
            (intent("stepIntent", "step", json!("sideways")), true),
            (intent("stepIntent", "step", Value::Null), true),
            (
                intent("compensationIntent", "descriptor", json!("readOnly")),
                false,
            ),
            (
                intent("compensationIntent", "descriptor", json!("deviceMutation")),
                true,
            ),
            (
                intent("stepOutcome", "step", json!("deviceMutation")),
                false,
            ),
        ] {
            assert_eq!(mutating_intent(&event), mutates, "{event}");
        }
    }
}
