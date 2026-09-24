//! The daemon's `cleanupDebt.continue` (Swift `AgentDaemon`'s handler over
//! `RuntimeJobEngine.continueCleanupDebt`): one outstanding cleanup debt,
//! continued explicitly, the ledger its write-ahead log.
//!
//! The debt outlives the Job that owed it. A terminal Job is not resident in
//! Swift's engine, so its durable record is loaded as restart recovery loads
//! it (`recover(records:)`, here [`recover_jobs`]), which marks a clean
//! journal `recovered: journal clean` and persists the record; every other
//! Job is resident and read as it stands. A Job whose outcome is unknown is
//! never touched. The debt's exact typed action, persisted when it was owed,
//! is materialized again and must name the recorded residue. A read-only
//! readback then judges the owned path or bundle first: already gone settles
//! the debt, inconclusive leaves it owed, and only a residue still present
//! may be retried — once. A retry already begun, or one whose outcome was
//! lost, forbids any resend. The retry dispatches under the capability use
//! the Job consumed (Swift's persisted-evidence arm: nothing new is consumed)
//! and is made durable before it is sent; its verdict settles the debt,
//! leaves it owed, or keeps its outcome unknown. A settled debt refreshes the
//! Job's residue count. Nothing is written to the Job's journal.
//!
//! The whole continuation runs in the mutation lane of the Job's Target
//! (`device_lane.rs`), entered before the ledger is read and held until it
//! answers, behind any Job — its own run included — or continuation that
//! asked for the device first; no device is touched without it. Swift's
//! continuation takes no lane; this is a declared difference.
use crate::cleanup_debt;
use crate::device_facts;
use crate::device_steps::{self, StepAction, StepContext};
use crate::job_record::{JobRecord, terminal};
use crate::job_recovery::recover_jobs;
use crate::job_run::JobRunner;
use crate::operation_catalog::CatalogOperation;
use crate::strict_json::swift_quoted;
use arkdeck_contract::WireError;
use arkdeck_provider_hdc::{
    DispatchFailure, FileReceipt, HapAction, NativeAction, Outcome, Reconcile,
};
use serde_json::{Map, Value, json};
use std::sync::atomic::{AtomicU64, Ordering};

/// Swift `RuntimeCleanupDebtContinuation.State`.
const SETTLED: &str = "settled";
const OUTSTANDING: &str = "outstanding";
const OUTCOME_UNKNOWN: &str = "outcomeUnknown";

/// Why a continuation was refused, as Swift's daemon answers it: a
/// `RuntimeJobEngineError` is `rejected`, any other error `internalError`,
/// each message the error as Swift interpolates it.
enum Refusal {
    Engine(String),
    Internal(String),
}

/// A `RuntimeJobEngineError` case with its payload.
fn engine(case: &str, detail: &str) -> Refusal {
    Refusal::Engine(format!("{case}({})", swift_quoted(detail)))
}

/// `RuntimeDispatchFailure.failed`.
fn failed(reason: &str) -> String {
    format!("failed({})", swift_quoted(reason))
}

/// `RuntimeDispatchFailure` as Swift interpolates it: a child that never
/// launched failed; one whose outcome was lost is `outcomeUnknown`.
fn dispatch_failure(failure: &DispatchFailure) -> String {
    match failure {
        DispatchFailure::Refused(reason) => failed(reason),
        DispatchFailure::Unobservable(reason) => {
            format!("outcomeUnknown({})", swift_quoted(reason))
        }
    }
}

/// The catalog descriptor a Job record names.
fn descriptor(reference: &str) -> Option<&'static CatalogOperation> {
    let (id, version) = reference.rsplit_once('@')?;
    CatalogOperation::lookup(id, version.parse().ok())
}

/// Swift `PersistedTypedProviderAction.materialize()` for the HDC families
/// whose cleanups the ledger can owe. A kind of any other family names no
/// residue here. Its refusal escapes Swift's `continueCleanupDebt` untouched
/// and the daemon answers it `internalError`, interpolated: a
/// `DeviceProviderError` by its detail alone (its `description`), an
/// `HDCE0RequestError` by its case — never the Rust error's own rendering.
/// A cleanup of a JPEG still is read with the still's own suffix, a declared
/// difference (Swift refuses the record, so the debt can never be continued).
fn materialize(persisted: &Value) -> Result<Option<StepAction>, Refusal> {
    let kind = persisted["kind"].as_str().unwrap_or_default();
    let empty = Map::new();
    let arguments = persisted["arguments"].as_object().unwrap_or(&empty);
    let internal = |error: arkdeck_provider_hdc::FileActionError| {
        Refusal::Internal(device_steps::refusal_detail(error))
    };
    if let Some(action) = HapAction::from_persisted(kind, arguments).map_err(internal)? {
        return Ok(Some(StepAction::Hap(action)));
    }
    Ok(NativeAction::from_persisted(kind, arguments)
        .map_err(internal)?
        .map(|action| StepAction::Native(Box::new(action))))
}

/// Swift `reconciliationReadback`: the read-only probe that judges the
/// cleanup's residue without resending the cleanup.
fn readback(action: &StepAction) -> Option<StepAction> {
    match action {
        StepAction::Hap(action) => action.readback().map(StepAction::Hap),
        StepAction::Native(action) => action
            .readback()
            .map(|readback| StepAction::Native(Box::new(readback))),
        _ => None,
    }
}

/// Swift `verifyReconciliationReadback`: the readback's verdict on the
/// cleanup. A native readback concludes by the native table; any other
/// needs a definite presence, which must be the one the cleanup wanted.
fn reconcile(action: &StepAction, readback: &StepAction, receipt: &FileReceipt) -> Reconcile {
    match (action, readback) {
        (StepAction::Native(action), StepAction::Native(readback)) => {
            action.reconcile(readback.verify(receipt))
        }
        (StepAction::Hap(action), StepAction::Hap(readback)) => {
            let present = match readback.verify(receipt, None) {
                Outcome::Verified(summary) => summary
                    .get("present")
                    .and_then(|raw| raw.parse::<bool>().ok()),
                _ => None,
            };
            match (present, action.desired_presence()) {
                (Some(present), Some(desired)) if present == desired => {
                    Reconcile::ConfirmedCompleted(
                        [("postconditionPresent".to_owned(), present.to_string())].into(),
                    )
                }
                (Some(_), Some(_)) => Reconcile::ConfirmedNotExecuted,
                (None, _) => Reconcile::StillUnknown(
                    "dedicated readback did not produce a definite presence".into(),
                ),
                (Some(_), None) => {
                    Reconcile::StillUnknown("readback was not paired with a mutation".into())
                }
            }
        }
        _ => Reconcile::StillUnknown("original action has no dedicated readback".into()),
    }
}

/// The cleanup's own verdict on its receipt.
fn verify(action: &StepAction, receipt: &FileReceipt) -> Outcome {
    match action {
        StepAction::Hap(action) => action.verify(receipt, None),
        StepAction::Native(action) => action.verify(receipt),
        _ => Outcome::Unsupported("cleanup debt action has no verdict here".into()),
    }
}

impl JobRunner<'_> {
    /// Swift `AgentDaemon`'s `cleanupDebt.continue`: either shape of residue
    /// names one ledger key — a remote path as it is, a bundle under its
    /// prefix — and the answer is the continuation's state and detail.
    pub fn continue_cleanup_debt(&self, params: &Map<String, Value>) -> Result<Value, WireError> {
        let wire = |code: &str, message: String| WireError {
            code: code.into(),
            message,
            details: None,
        };
        let identity = match (params.get("remotePath"), params.get("bundleName")) {
            (Some(Value::String(path)), _) => Some(path.clone()),
            (_, Some(Value::String(bundle))) => Some(format!("bundle:{bundle}")),
            _ => None,
        };
        let (Some(Value::String(job_id)), Some(identity)) = (params.get("jobId"), identity) else {
            return Err(wire(
                "invalidParams",
                "jobId and one of remotePath / bundleName are required".into(),
            ));
        };
        match self.continue_debt(job_id, &identity) {
            Ok((state, detail)) => Ok(json!({
                "jobId": job_id, "identity": identity, "state": state, "detail": detail,
            })),
            Err(Refusal::Engine(message)) => Err(wire("rejected", message)),
            Err(Refusal::Internal(message)) => Err(wire("internalError", message)),
        }
    }

    fn continue_debt(
        &self,
        job_id: &str,
        identity: &str,
    ) -> Result<(&'static str, String), Refusal> {
        // The readback and the one retry are device work on the Job's
        // Target: they wait their turn in its mutation lane, as a request of
        // their own, before the ledger and the Job are read, so what they
        // decide on cannot change under them (a declared difference: Swift's
        // continuation takes no lane).
        let lane = self.debt_lane(job_id, identity);
        let debt = cleanup_debt::outstanding_record(self.artifacts, job_id, identity)
            .map_err(Refusal::Internal)?
            .ok_or_else(|| engine("jobNotFound", &format!("cleanup-debt:{job_id}:{identity}")))?;
        let record = self.continued_job(job_id)?;
        if record.outcome_unknown() {
            return Ok((
                OUTCOME_UNKNOWN,
                "job has an unresolved outcome; cleanup mutation is not resent".into(),
            ));
        }
        let Some(persisted) = debt.get("persistedAction") else {
            return Err(engine(
                "internalFailure",
                "cleanup debt has no persisted exact typed action",
            ));
        };
        let action = materialize(persisted)?;
        let owed = action
            .as_ref()
            .and_then(device_steps::cleanup_residue)
            .map(|residue| residue.identity());
        let (Some(action), Some(owed)) = (action, owed) else {
            return Err(engine(
                "internalFailure",
                "cleanup debt action does not match its recorded residue",
            ));
        };
        if owed != identity {
            return Err(engine(
                "internalFailure",
                "cleanup debt action does not match its recorded residue",
            ));
        }
        let hdc = match self.hdc {
            Some(hdc) if record.provider() == "hdc" => hdc,
            _ => {
                return Err(engine(
                    "internalFailure",
                    &format!("provider {} is unavailable", record.provider()),
                ));
            }
        };
        let target_id = record.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default();
        let revision = record.request["target"]["expectedBindingRevision"].as_i64();
        // No device is touched outside the lane.
        let _lane = match lane {
            Ok(Some(lane)) => lane,
            Ok(None) => {
                return Err(Refusal::Internal(
                    "the Job's Target mutation lane was not entered".into(),
                ));
            }
            Err(refusal) => return Err(Refusal::Internal(refusal)),
        };
        let facts = hdc.facts(target_id).map_err(Refusal::Internal)?;
        device_facts::validate(&facts, target_id, revision)
            .map_err(|reason| Refusal::Internal(failed(reason)))?;
        let step_id = debt["stepID"].as_str().unwrap_or_default();
        let context = StepContext {
            job_id,
            resolved: &[],
            library: None,
            helper: hdc.code_sign_helper,
        };
        let connect_key = Some(facts.connect_key.as_str());

        // The read-only judgement first: never a resend for a residue that
        // is already gone or that cannot be judged.
        let Some(readback) = readback(&action)
            .filter(|readback| matches!(readback.effect(), "readOnly" | "hostOnly"))
        else {
            return Err(engine(
                "internalFailure",
                "cleanup debt has no dedicated read-only path judgement",
            ));
        };
        let probe = readback
            .plan(step_id, connect_key, &context)
            .map_err(Refusal::Internal)?;
        match arkdeck_provider_hdc::run(&probe, hdc.dispatch) {
            Err(failure) => {
                return Ok((
                    OUTSTANDING,
                    format!("path readback failed: {}", dispatch_failure(&failure)),
                ));
            }
            Ok(receipt) => match reconcile(&action, &readback, &receipt) {
                Reconcile::ConfirmedCompleted(_) => {
                    // Swift settles inside the readback's error lane.
                    if let Err(error) = self.settle(job_id, identity) {
                        return Ok((OUTSTANDING, format!("path readback failed: {error}")));
                    }
                    return Ok((
                        SETTLED,
                        "readback confirmed the owned path is already absent".into(),
                    ));
                }
                Reconcile::ConfirmedNotExecuted => {}
                Reconcile::StillUnknown(reason) => {
                    return Ok((OUTSTANDING, format!("path readback inconclusive: {reason}")));
                }
            },
        }

        // The one retry the debt allows.
        if debt["retryOutcomeUnknown"] == true || debt.get("retryAttemptStartedAtUTC").is_some() {
            return Ok((
                OUTCOME_UNKNOWN,
                "earlier cleanup retry is outcomeUnknown; mutation resend is forbidden".into(),
            ));
        }
        let plan = action
            .plan(step_id, connect_key, &context)
            .map_err(Refusal::Internal)?;
        if action.effect() != "deviceMutation" {
            return Err(engine(
                "internalFailure",
                "cleanup debt did not lower to its exact typed mutation",
            ));
        }
        let Some(descriptor) = descriptor(record.operation()) else {
            return Err(engine(
                "internalFailure",
                &format!("catalog operation vanished for {job_id}"),
            ));
        };
        let now = self.continuation_clock()?;
        self.continue_held_use(&record, descriptor, &facts, &now)
            .map_err(|reason| Refusal::Internal(failed(&reason)))?;
        // Durable before it is sent: a lost outcome can never be resent.
        cleanup_debt::begin_retry(self.artifacts, job_id, identity, &now)
            .map_err(Refusal::Internal)?;
        match arkdeck_provider_hdc::run(&plan, hdc.dispatch) {
            Ok(receipt) => match verify(&action, &receipt) {
                Outcome::Verified(_) => {
                    self.settle(job_id, identity).map_err(Refusal::Internal)?;
                    Ok((SETTLED, "exact typed cleanup completed".into()))
                }
                Outcome::Failed { code, detail } => {
                    cleanup_debt::complete_retry(self.artifacts, job_id, identity, false)
                        .map_err(Refusal::Internal)?;
                    Ok((OUTSTANDING, format!("{code}: {detail}")))
                }
                Outcome::Unknown(reason) | Outcome::Unsupported(reason) => {
                    cleanup_debt::complete_retry(self.artifacts, job_id, identity, true)
                        .map_err(Refusal::Internal)?;
                    Ok((
                        OUTCOME_UNKNOWN,
                        format!("{reason}; mutation resend is forbidden"),
                    ))
                }
            },
            Err(failure) => {
                let unknown = matches!(failure, DispatchFailure::Unobservable(_));
                cleanup_debt::complete_retry(self.artifacts, job_id, identity, unknown)
                    .map_err(Refusal::Internal)?;
                Ok((
                    if unknown {
                        OUTCOME_UNKNOWN
                    } else {
                        OUTSTANDING
                    },
                    dispatch_failure(&failure),
                ))
            }
        }
    }

    /// The Job the debt belongs to, as Swift's engine holds it: a terminal
    /// Job whose outcome is known is not resident, so it is loaded as
    /// restart recovery loads it, which may mark and persist its record;
    /// any other Job is resident and read as it stands.
    fn continued_job(&self, job_id: &str) -> Result<JobRecord, Refusal> {
        let read = |job_id: &str| match self.jobs.read_snapshot(job_id) {
            Ok(record) => Ok(record),
            Err(error) if error.code == "notFound" => Err(engine("jobNotFound", job_id)),
            Err(error) => Err(Refusal::Internal(error.message)),
        };
        let record = read(job_id)?;
        if !terminal(&record.state) || record.outcome_unknown() {
            return Ok(record);
        }
        let capabilities = self.mutation.map(|owner| owner.authority.capabilities);
        let recovered = recover_jobs(self.jobs, &[job_id.to_owned()], capabilities, self.now)
            .map_err(|error| Refusal::Engine(error.0))?;
        // A record recovery cannot read never becomes resident.
        if recovered.quarantined.iter().any(|(id, _)| id == job_id) {
            return Err(engine("jobNotFound", job_id));
        }
        if let Some((_, reason)) = recovered.refused.iter().find(|(id, _)| id == job_id) {
            return Err(engine("internalFailure", reason));
        }
        read(job_id)
    }

    /// Swift `settleCleanupDebt` then `refreshResidueCount`: the debt settled,
    /// and the Job's outstanding residues counted again and persisted, as a
    /// best effort.
    fn settle(&self, job_id: &str, identity: &str) -> Result<(), String> {
        let now = (self.now)().ok_or_else(|| "the Runtime clock is unavailable".to_owned())?;
        cleanup_debt::settle(self.artifacts, job_id, identity, &now)?;
        if let Ok(mut record) = self.jobs.read_snapshot(job_id) {
            let owed = cleanup_debt::outstanding(self.artifacts, job_id).unwrap_or(0);
            record.set_residues(i64::try_from(owed).unwrap_or(i64::MAX));
            let _ = self.jobs.persist(&record, &now);
        }
        Ok(())
    }

    fn continuation_clock(&self) -> Result<String, Refusal> {
        (self.now)().ok_or_else(|| engine("internalFailure", "the Runtime clock is unavailable"))
    }
}

/// Tells one continuation's lane request from every other of this process.
static CONTINUATIONS: AtomicU64 = AtomicU64::new(0);

impl<'a> JobRunner<'a> {
    /// The mutation lane of the Target the debt's Job names, entered for this
    /// continuation alone, waiting behind whoever asked first, before any
    /// Target transaction of the continuation (lane first, transactions
    /// after); none when the Job cannot be read or is not an HDC Job run
    /// through this composition, which the continuation then refuses before
    /// any device work. The refusal is why a lane could not be entered.
    fn debt_lane(
        &self,
        job_id: &str,
        identity: &str,
    ) -> Result<Option<crate::MutationLane<'a>>, String> {
        let (Ok(record), Some(hdc)) = (self.jobs.read_snapshot(job_id), self.hdc) else {
            return Ok(None);
        };
        if record.provider() != "hdc" {
            return Ok(None);
        }
        let holder = format!(
            "cleanup-debt:{job_id}:{identity}:{}",
            CONTINUATIONS.fetch_add(1, Ordering::Relaxed)
        );
        let target = record.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default();
        hdc.targets.enter_mutation_lane(target, &holder, None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn refusal(persisted: Value) -> String {
        match materialize(&persisted) {
            Err(Refusal::Internal(message)) => message,
            Err(Refusal::Engine(message)) => panic!("an engine refusal: {message}"),
            Ok(_) => panic!("{persisted} materialized"),
        }
    }

    /// Swift's `continueCleanupDebt` lets `materialize()`'s error escape, and
    /// its daemon answers any error that is not the engine's `internalError`
    /// with `"\(error)"`: a `DeviceProviderError` is its `description`, the
    /// detail alone, and an `HDCE0RequestError` its case with its fields.
    #[test]
    fn a_refused_debt_action_is_answered_as_swift_interpolates_it() {
        let job = "job-dc1692ef72c638e3e97ef1344f891ab4";
        assert_eq!(
            refusal(json!({"kind": "hdc.cleanupOwnedRemotePath", "arguments": {
                "jobId": job, "stepId": "capture-ui-tree", "nonce": "owned",
                "remotePath": "/data/local/tmp/elsewhere.json"}})),
            "persisted hdc.cleanupOwnedRemotePath remote path does not match its owned components"
        );
        assert_eq!(
            refusal(json!({"kind": "hdc.cleanupOwnedRemotePath", "arguments": {
                "jobId": job, "stepId": "capture-ui-tree", "nonce": "owned"}})),
            "persisted hdc.cleanupOwnedRemotePath is missing string remotePath"
        );
        assert_eq!(
            refusal(json!({"kind": "hdc.uninstallPackage", "arguments": {"bundleName": "demo"}})),
            "malformed(field: \"bundleName\", detail: \"reverse-DNS identifier expected\")"
        );
    }

    /// A declared difference from Swift, which rebuilds a JPEG still's path
    /// with the PNG suffix and refuses the debt: the still's cleanup is read
    /// with its own suffix, and names the very residue the ledger owes.
    #[test]
    fn a_jpeg_still_cleanup_debt_names_its_own_residue() {
        let job = "job-02ff97a6ccf8d97ce49e6fecaa197f6f";
        let path = format!("/data/local/tmp/arkdeck-{job}-capture-screenshot-owned.jpeg");
        let action = materialize(&json!({"kind": "hdc.cleanupOwnedRemotePath", "arguments": {
            "jobId": job, "stepId": "capture-screenshot", "nonce": "owned",
            "remotePath": path}}))
        .ok()
        .flatten()
        .expect("a JPEG still's cleanup");
        assert_eq!(
            device_steps::cleanup_residue(&action).map(|residue| residue.identity()),
            Some(path)
        );
    }
}
