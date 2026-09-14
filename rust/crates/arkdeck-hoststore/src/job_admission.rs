//! Rust `job.submit` for the operations this Runtime materializes: Swift
//! `RuntimeJobEngine.submitOwned` as the target control plane calls it. The
//! idempotency lookup comes before materialization; a new Job is admitted under
//! the default read-only policy (no capability is read, reserved or consumed),
//! its journal then starts with `jobCreated` and `queued -> preflight`, and its
//! record is published. Nothing is dispatched: an admitted Job waits in
//! `preflight` for an executor.
use crate::JobStore;
use crate::job_journal_events::{self, Envelope};
use crate::job_journal_writer::JournalWriter;
use crate::job_plan::{JobPlanner, PlanRefusal, request_json};
use crate::job_record::JobRecord;
use crate::job_repository::AdmissionVerdict;
use crate::operation_catalog::CatalogOperation;
use crate::operation_request::OperationRequest;
use arkdeck_contract::{CATALOG_DIGEST, sha256_hex};
use serde_json::{Map, Value, json};

/// Swift `RuntimeDefaultReadOnlyPolicy` bounds.
const READ_ONLY_TIMEOUT_SECONDS: i64 = 900;
const READ_ONLY_OUTPUT_BYTES: i64 = 1 << 29;

/// A `job.submit` refusal. `proven` refusals came before the durable
/// admission point and carry the zero-dispatch proof; a failure after it
/// does not.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AdmissionRefusal {
    pub code: &'static str,
    pub message: String,
    pub proven: bool,
}

impl From<PlanRefusal> for AdmissionRefusal {
    fn from(refusal: PlanRefusal) -> Self {
        Self {
            code: refusal.code,
            message: refusal.message,
            proven: true,
        }
    }
}

fn refused(code: &'static str, message: impl Into<String>) -> AdmissionRefusal {
    AdmissionRefusal {
        code,
        message: message.into(),
        proven: true,
    }
}

/// Swift reports every failure outside its typed refusals with one message
/// and, for a submit, without the zero-dispatch proof.
fn uncertain() -> AdmissionRefusal {
    AdmissionRefusal {
        code: "internalError",
        message: "the Runtime could not complete the Job lifecycle request".into(),
        proven: false,
    }
}

fn conflict() -> AdmissionRefusal {
    refused(
        "idempotencyConflict",
        "idempotency key reuse with a different request",
    )
}

fn acceptance(job_id: &str, deduplicated: bool) -> Value {
    json!({"schemaVersion": "arkdeck.job-acceptance/1", "jobId": job_id,
        "deduplicated": deduplicated, "newDispatchCount": 0})
}

/// The Runtime clock: now, as Swift durable records spell it.
pub fn runtime_now() -> Option<String> {
    crate::format_time::utc_now()
}

/// Swift `preauthorize` for an effect of at most `readOnly`: the catalog's
/// default read-only policy within the policy's bounds, recorded as
/// admission evidence. Anything above `readOnly` needs a Runtime capability,
/// which this Runtime does not issue yet.
fn default_read_only(
    descriptor: &CatalogOperation,
    effect: &str,
    admitted_at: &str,
) -> Result<Value, AdmissionRefusal> {
    let reference = descriptor.reference();
    if !matches!(effect, "hostOnly" | "readOnly") {
        return Err(refused(
            "rejected",
            format!(
                "{reference} needs a Runtime capability, which the Rust Runtime does not issue yet"
            ),
        ));
    }
    if descriptor.authorization.get(effect).map(String::as_str) != Some("defaultReadOnly") {
        return Err(refused(
            "admissionDenied",
            format!("catalog has no default read-only policy for {reference}"),
        ));
    }
    let denied = |decision: String| {
        Err(refused(
            "admissionDenied",
            format!("default read-only policy denied: {decision}"),
        ))
    };
    if descriptor.timeout_seconds > READ_ONLY_TIMEOUT_SECONDS {
        return denied(format!(
            "deniedTimeoutAboveLimit(requested: {}, limit: {READ_ONLY_TIMEOUT_SECONDS})",
            descriptor.timeout_seconds
        ));
    }
    if descriptor.output_byte_budget > READ_ONLY_OUTPUT_BYTES {
        return denied(format!(
            "deniedBudgetAboveLimit(requested: {}, limit: {READ_ONLY_OUTPUT_BYTES})",
            descriptor.output_byte_budget
        ));
    }
    Ok(
        json!({"kind": "defaultReadOnlyPolicy", "reference": "default-read-only-policy",
        "admittedAtUTC": admitted_at}),
    )
}

/// The owners an admission writes: the Job store, through the planner's
/// materialization, at the time the clock gives.
pub struct JobAdmitter<'a> {
    pub planner: JobPlanner<'a>,
    pub jobs: &'a JobStore,
    pub now: fn() -> Option<String>,
}

impl JobAdmitter<'_> {
    /// The `job.submit` control parameters: exactly one bounded `requestJson`.
    pub fn handle(&self, params: &Map<String, Value>) -> Result<Value, AdmissionRefusal> {
        self.submit(request_json(params)?.as_bytes())
    }

    pub fn submit(&self, request_json: &[u8]) -> Result<Value, AdmissionRefusal> {
        let request = OperationRequest::decode(request_json)
            .map_err(|rejection| refused(rejection.code.wire_code(), rejection.message))?;
        let descriptor = JobPlanner::descriptor(&request)?;
        JobPlanner::validate_inputs(&request, descriptor)?;
        // A retry or a conflict is decided before anything is materialized.
        let fingerprint = request.fingerprint();
        match self
            .jobs
            .lookup(&request.idempotency_key, &fingerprint)
            .map_err(|_| uncertain())?
        {
            AdmissionVerdict::Duplicate(job_id) => return self.duplicate(&job_id, &request, false),
            AdmissionVerdict::Conflict => return Err(conflict()),
            AdmissionVerdict::Admitted => (),
        }
        let effect = descriptor.effective_effect(&request.inputs);
        let job_id = format!(
            "job-{}",
            &sha256_hex(format!("{}\n{fingerprint}", request.idempotency_key).as_bytes())[..32]
        );
        let materialized = self.planner.materialized(&request, descriptor)?;
        if request
            .reviewed_plan_digest
            .as_ref()
            .is_some_and(|reviewed| *reviewed != materialized.digest)
        {
            return Err(refused(
                "reviewedPlanMismatch",
                "the fresh materialized plan differs from the immutable reviewed plan",
            ));
        }
        let evidence = default_read_only(descriptor, &effect, &self.clock()?)?;
        let timestamp = self.clock()?;
        let mut record = JobRecord::admitted(
            &job_id,
            request.canonical_value(),
            &descriptor.reference(),
            CATALOG_DIGEST,
            &descriptor.provider,
            &timestamp,
            &effect,
            evidence,
            &materialized.digest,
        );
        record.set_materialized(materialized.identity, materialized.binding_revision);
        match self
            .jobs
            .admit(&record, &fingerprint)
            .map_err(|_| uncertain())?
        {
            AdmissionVerdict::Duplicate(existing) => {
                return self.duplicate(&existing, &request, true);
            }
            AdmissionVerdict::Conflict => return Err(conflict()),
            AdmissionVerdict::Admitted => (),
        }
        // Past the durable admission point: a failure below is uncertain.
        self.start(&record, &timestamp).ok_or_else(uncertain)?;
        Ok(acceptance(&job_id, false))
    }

    /// Swift `currentCatalogDuplicate` and the reviewed-plan check of a
    /// deduplicated submit. A concurrent duplicate found at admission answers
    /// a reviewed-plan mismatch as the conflict Swift reports there.
    fn duplicate(
        &self,
        job_id: &str,
        request: &OperationRequest,
        concurrent: bool,
    ) -> Result<Value, AdmissionRefusal> {
        let existing = self.jobs.read_snapshot(job_id).map_err(|error| {
            if error.code == "notFound" {
                refused("resourceNotFound", "the referenced Job does not exist")
            } else {
                refused(
                    "recordUnreadable",
                    "the referenced Job record is unreadable",
                )
            }
        })?;
        if existing.catalog_digest() != CATALOG_DIGEST {
            return Err(refused(
                "idempotencyConflict",
                "idempotency key belongs to a Job admitted under a different Catalog digest",
            ));
        }
        if let Some(reviewed) = &request.reviewed_plan_digest
            && existing.plan_digest() != Some(reviewed.as_str())
        {
            return Err(if concurrent {
                refused(
                    "resourceConflict",
                    "concurrent duplicate plan digest differs from the reviewed plan; zero new dispatch",
                )
            } else {
                refused(
                    "reviewedPlanMismatch",
                    "the existing Job differs from the immutable reviewed plan",
                )
            });
        }
        Ok(acceptance(job_id, true))
    }

    /// Before admission a clock failure changes nothing.
    fn clock(&self) -> Result<String, AdmissionRefusal> {
        (self.now)().ok_or_else(|| {
            refused(
                "internalError",
                "the Runtime could not complete the Job lifecycle request",
            )
        })
    }

    /// Swift's journal initialization and `persistRuntimeRecord` after
    /// admission: `jobCreated` and `queued -> preflight` in the Job's journal,
    /// then the record, at the index's next version.
    fn start(&self, record: &JobRecord, timestamp: &str) -> Option<()> {
        let job_id = record.job_id.as_str();
        let directory = self.jobs.job_directory(job_id).ok()?;
        let mut journal = JournalWriter::open(&directory, true).ok()?;
        let envelope = |event_id: &str, sequence: i64| Envelope {
            event_id: event_id.into(),
            sequence,
            session_id: format!("session-{job_id}"),
            job_id: job_id.into(),
            timestamp: timestamp.into(),
        };
        journal
            .append(&job_journal_events::job_created(
                &envelope("job-created", 0),
                "execute",
                "standardAgent",
                "CORE-2.0.0",
            ))
            .ok()?;
        journal
            .append(&job_journal_events::state_transition(
                &envelope("to-preflight", 1),
                "queued",
                "preflight",
                "admitted",
                None,
            ))
            .ok()?;
        self.jobs.persist(record, &(self.now)()?).ok()
    }
}
