//! Rust `job.submit` for the operations this Runtime materializes: Swift
//! `RuntimeJobEngine.submitOwned` as the target control plane calls it.
//! - The idempotency lookup comes before materialization.
//! - A new read-only Job is admitted under the default read-only policy.
//! - A device mutation the catalog authorizes with a standing capability is
//!   admitted under the capability the caller names or, when it names none,
//!   the one the Runtime issues (`capability_policy`), which for `debug.hap@1`
//!   is also named by the entry package's owner-validated Artifact facts.
//!   Either is checked against its envelope and lineage; no use is reserved
//!   or consumed.
//! - A workspace mutation is admitted only against a Runtime-owned isolated
//!   copy, under the capability the Runtime issues for that copy's tree,
//!   revision and scopes (or one the caller names). A person's primary tree
//!   needs a standing capability a person issued, which this Runtime neither
//!   issues nor honours: its request is refused before admission.
//! - The Job's journal then starts with `jobCreated` and `queued -> preflight`,
//!   and its record is published.
//!
//! Nothing is dispatched: an admitted Job waits in `preflight` for an
//! executor.
use crate::JobStore;
use crate::capability_policy::{self, DeviceHolds, IssueFailure};
use crate::capability_store::{CapabilityQuery, CapabilityStore, CapabilityStoreError, Effect};
use crate::job_journal_events::{self, Envelope};
use crate::job_journal_writer::JournalWriter;
use crate::job_plan::{JobPlanner, Materialized, PlanRefusal, request_json};
use crate::job_record::JobRecord;
use crate::job_repository::AdmissionVerdict;
use crate::operation_catalog::CatalogOperation;
use crate::operation_request::OperationRequest;
use arkdeck_contract::{CATALOG_DIGEST, sha256_hex};
use serde_json::{Map, Value, json};

#[path = "flash_admission.rs"]
mod flash_admission;
pub use flash_admission::FlashAdmitter;

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

fn interlock_refusal(error: arkdeck_contract::WireError) -> AdmissionRefusal {
    refused(
        if error.code == "resourceConflict" {
            "resourceConflict"
        } else {
            "internalError"
        },
        error.message,
    )
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
/// admission evidence.
fn default_read_only(
    descriptor: &CatalogOperation,
    effect: &str,
    admitted_at: &str,
) -> Result<Value, AdmissionRefusal> {
    let reference = descriptor.reference();
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

/// Swift `denialCode(of:)`: the machine-readable half of a capability
/// refusal. Only decisions are named; a store fault is `unclassified`.
fn denial_code(error: &CapabilityStoreError) -> &'static str {
    match error {
        CapabilityStoreError::Denied(denial) => denial.reason,
        CapabilityStoreError::LineageBlocked(_) => "lineageBlocked",
        CapabilityStoreError::NotFound(_) => "capabilityNotFound",
        _ => "unclassified",
    }
}

/// What a device mutation is authorized from: the capability store, and the
/// device sessions this daemon holds.
#[derive(Clone, Copy)]
pub struct MutationAuthority<'a> {
    pub default_root: &'a std::path::Path,
    pub sessions: Option<&'a crate::SessionStore>,
    pub capabilities: &'a CapabilityStore,
    pub holds: &'a DeviceHolds,
}

impl MutationAuthority<'_> {
    /// Swift's `validateMutationState`, before an admission and before each
    /// consumption: the Runtime's mutation state is continuous across the
    /// default root and the Session root the storage status names. That
    /// status is read as Swift reads it, waiting for the storage lock: a
    /// device mutation submitted while the previous Job's Session is being
    /// published is admitted once the publication releases the lock, never
    /// refused because it holds it.
    pub fn require_state(&self, jobs: &JobStore) -> Result<(), arkdeck_contract::WireError> {
        let status = match self.sessions {
            Some(sessions) => Some(sessions.waited_status()?),
            None => None,
        };
        self.prove(jobs, status.as_ref())
    }

    /// Whether the mutation state is proved now, as the operation
    /// availability report asks it, without waiting for the storage lock: a
    /// held lock reads as not proved. Swift's availability reads no storage,
    /// so a publication or an export in flight must not make `operation.list`
    /// wait.
    pub fn state_proven_now(&self, jobs: &JobStore) -> bool {
        let status = match self
            .sessions
            .map(crate::SessionStore::status_without_waiting)
        {
            Some(Ok(status)) => Some(status),
            Some(Err(_)) => return false,
            None => None,
        };
        self.prove(jobs, status.as_ref()).is_ok()
    }

    fn prove(
        &self,
        jobs: &JobStore,
        status: Option<&Value>,
    ) -> Result<(), arkdeck_contract::WireError> {
        let mut roots = Vec::new();
        if let Some(status) = status {
            let root = status["rootPath"]
                .as_str()
                .ok_or_else(|| arkdeck_contract::WireError {
                    code: "recordUnreadable".into(),
                    message: "Runtime Session root is unreadable".into(),
                    details: None,
                })?;
            roots.push(std::path::PathBuf::from(root));
        }
        jobs.require_mutation_state(self.default_root, &roots)
    }
}

/// The owners an admission writes: the Job store, through the planner's
/// materialization, at the time the clock gives. Without an authority no
/// device mutation is admitted.
pub struct JobAdmitter<'a> {
    pub planner: JobPlanner<'a>,
    pub jobs: &'a JobStore,
    pub now: fn() -> Option<String>,
    pub authority: Option<MutationAuthority<'a>>,
}

impl JobAdmitter<'_> {
    /// The `job.submit` control parameters: exactly one bounded `requestJson`.
    pub fn handle(&self, params: &Map<String, Value>) -> Result<Value, AdmissionRefusal> {
        self.submit(request_json(params)?.as_bytes())
    }

    /// Swift `submitForAgent`, as far as this Runtime serves it. An agent
    /// execution starts the Job it comes to own at once, so it is admitted
    /// only for an operation this Runtime also executes. Any other request
    /// is refused with the zero-dispatch proof before anything is
    /// materialized, as an operation outside the plan allowlist is; a
    /// `job.submit` of it is still admitted and waits in `preflight`.
    pub fn submit_for_agent(&self, request_json: &[u8]) -> Result<Value, AdmissionRefusal> {
        let request = OperationRequest::decode(request_json)
            .map_err(|rejection| refused(rejection.code.wire_code(), rejection.message))?;
        let reference = JobPlanner::descriptor(&request)?.reference();
        if !crate::job_run::executes(&reference) {
            return Err(refused(
                "rejected",
                format!("{reference} is not executed by the Rust Runtime yet"),
            ));
        }
        self.submit(request_json)
    }

    pub fn submit(&self, request_json: &[u8]) -> Result<Value, AdmissionRefusal> {
        let request = OperationRequest::decode(request_json)
            .map_err(|rejection| refused(rejection.code.wire_code(), rejection.message))?;
        let descriptor = JobPlanner::descriptor(&request).map_err(|refused| {
            self.planner
                .unmaterialized_analyzer(&request)
                .unwrap_or(refused)
        })?;
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
        drop(self.jobs.admission_interlock().map_err(interlock_refusal)?);
        let effect = descriptor.effective_effect(&request.inputs);
        // Swift `repairProvablyTerminalCapabilityOutcomeGaps`, before the
        // plan is materialized: a use whose Job's journal already proves it
        // settled is recorded again, and nothing is dispatched.
        if !matches!(effect.as_str(), "hostOnly" | "readOnly")
            && let (Some(revision), Some(authority)) =
                (request.expected_binding_revision, self.authority)
        {
            crate::job_lineage_repair::repair_outcome_gaps(
                self.jobs,
                authority.capabilities,
                &request.target_id,
                revision,
                self.now,
            )
            .map_err(|_| uncertain())?;
        }
        let job_id = format!(
            "job-{}",
            &sha256_hex(format!("{}\n{fingerprint}", request.idempotency_key).as_bytes())[..32]
        );
        let materialized = self.planner.materialized(&request, descriptor)?;
        // Materialization may have overlapped the final lifecycle census.
        // Hold admission through authority issuance and the durable index
        // commit; the lifecycle cannot slip between the check and commit.
        let admission = self.jobs.admission_interlock().map_err(interlock_refusal)?;
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
        // A device mutation runs the request that names its capability; the
        // caller's own stays the original submission.
        let (evidence, executed) = if matches!(effect.as_str(), "hostOnly" | "readOnly") {
            let evidence = default_read_only(descriptor, &effect, &self.clock()?)?;
            (Some(evidence), request.canonical_value())
        } else {
            let capability = self.preauthorize(&request, descriptor, &effect, &materialized)?;
            let mut authorized = request.clone();
            authorized.capability_id = Some(capability);
            (None, authorized.canonical_value())
        };
        let timestamp = self.clock()?;
        let mut record = JobRecord::admitted(
            &job_id,
            executed,
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
        match admission
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

    /// Swift `preauthorize` above `readOnly`:
    /// 1. another client's live device session is refused;
    /// 2. then the catalog's policy is read;
    /// 3. a standing capability the caller names is used as named;
    /// 4. without one, the Runtime issues its own when the catalog lets it.
    ///
    /// Either capability is checked against its envelope and lineage before
    /// admission, and nothing is consumed yet. A destructive effect and the
    /// Runtime-capability policy are not served yet; a workspace subject is
    /// `preauthorize_workspace`'s.
    fn preauthorize(
        &self,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
        effect: &str,
        materialized: &Materialized<'_>,
    ) -> Result<String, AdmissionRefusal> {
        let reference = descriptor.reference();
        let unserved = || {
            refused(
                "rejected",
                format!(
                    "{reference} needs a Runtime capability, which the Rust Runtime does not issue yet"
                ),
            )
        };
        if descriptor.provider == "workspace" {
            return self.preauthorize_workspace(request, descriptor, effect, materialized);
        }
        let (Some(authority), Some(parsed)) = (self.authority, Effect::parse(effect)) else {
            return Err(unserved());
        };
        authority
            .require_state(self.jobs)
            .map_err(|error| refused("admissionDenied", error.message))?;
        let session_scoped = capability_policy::session_scoped(descriptor, &request.inputs);
        let client = request
            .client_context
            .as_ref()
            .and_then(|context| context.client_name.as_deref())
            .unwrap_or("anonymous");
        authority
            .holds
            .admit(
                materialized.identity.as_deref(),
                client,
                session_scoped,
                &self.clock()?,
            )
            .map_err(|message| refused("resourceConflict", message))?;
        let Some(policy) = descriptor.authorization.get(effect) else {
            return Err(refused(
                "admissionDenied",
                format!("catalog has no authorization policy for effect {effect}"),
            ));
        };
        let (Some(identity), Some(binding_revision)) =
            (&materialized.identity, materialized.binding_revision)
        else {
            return Err(unserved());
        };
        if parsed == Effect::Destructive || policy == "runtimeCapability" {
            return Err(unserved());
        }
        let query = CapabilityQuery {
            operation_id: descriptor.id().to_owned(),
            operation_version: descriptor.version(),
            effect: parsed,
            target_stable_identity_sha256: Some(identity.clone()),
            target_binding_revision: Some(binding_revision),
            plan_digest: Some(materialized.digest.clone()),
            inputs: capability_policy::subject(descriptor, &request.inputs),
            // Facts come from the exact owner-validated materialization.
            artifact_facts: materialized.artifact_facts.clone(),
            workspace_identity_sha256: None,
            workspace_revision: None,
            workspace_file_scopes_digest: None,
        };
        let capability = if let Some(supplied) = &request.capability_id {
            supplied.clone()
        } else if parsed == Effect::DeviceMutation
            && policy == "standingCapability"
            && descriptor.default_policy_issuance()
        {
            capability_policy::issue(
                authority.capabilities,
                descriptor,
                &query,
                session_scoped,
                &self.clock()?,
            )
            .map_err(|failure| match failure {
                IssueFailure::Refused(message) => refused("admissionDenied", message),
                // Swift's engine reports a store it cannot read without the
                // zero-dispatch proof.
                IssueFailure::Unreadable => uncertain(),
            })?
        } else {
            return Err(refused(
                "admissionDenied",
                format!("effect {effect} requires an explicit runtime capability"),
            ));
        };
        authority
            .capabilities
            .validate_new_execution(&capability, &query, &self.clock()?)
            .map_err(|error| {
                refused(
                    "admissionDenied",
                    format!(
                        "capability denied [denial:{}]: {}",
                        denial_code(&error),
                        error.swift()
                    ),
                )
            })?;
        Ok(capability)
    }

    /// Swift `preauthorize` for a workspace subject above `readOnly`. The
    /// facts of the tree the request names decide issuance:
    /// - a Runtime-owned isolated copy is issued the Runtime's own capability
    ///   when the caller names none (`automatic_issuance_permitted`), and one
    ///   the caller names is used as named;
    /// - a person's primary tree needs a standing capability a person issued,
    ///   and this Runtime holds no path that issues or honours one: a request
    ///   naming none is refused as Swift refuses it, and one naming any is
    ///   refused as Swift refuses a capability its store does not hold;
    /// - an operation whose catalog policy is the Runtime's own
    ///   (`runtimeCapability`) is issued the Runtime's one-use capability for
    ///   the exact plan, for a primary tree and a copy alike, and a request
    ///   naming any capability is refused.
    ///
    /// Either capability is then checked against its envelope and lineage;
    /// nothing is reserved or consumed, and every refusal dispatches nothing.
    fn preauthorize_workspace(
        &self,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
        effect: &str,
        materialized: &Materialized<'_>,
    ) -> Result<String, AdmissionRefusal> {
        let reference = descriptor.reference();
        let unserved = || {
            refused(
                "rejected",
                format!(
                    "{reference} needs a Runtime capability, which the Rust Runtime does not issue yet"
                ),
            )
        };
        let (Some(authority), Some(workspace), Some(parsed)) = (
            self.authority,
            self.planner.workspace,
            Effect::parse(effect),
        ) else {
            return Err(unserved());
        };
        authority
            .require_state(self.jobs)
            .map_err(|error| refused("admissionDenied", error.message))?;
        let Some(policy) = descriptor.authorization.get(effect) else {
            return Err(refused(
                "admissionDenied",
                format!("catalog has no authorization policy for effect {effect}"),
            ));
        };
        // The subject is the tree the request names, measured now.
        let facts = workspace
            .authorization_facts(&request.inputs)
            .map_err(|error| refused("admissionDenied", error))?;
        if parsed == Effect::Destructive {
            return Err(unserved());
        }
        let query = CapabilityQuery {
            operation_id: descriptor.id().to_owned(),
            operation_version: descriptor.version(),
            effect: parsed,
            target_stable_identity_sha256: None,
            target_binding_revision: None,
            plan_digest: Some(materialized.digest.clone()),
            inputs: request.inputs.clone(),
            artifact_facts: materialized.artifact_facts.clone(),
            workspace_identity_sha256: Some(facts.identity_sha256.clone()),
            workspace_revision: Some(facts.revision.clone()),
            workspace_file_scopes_digest: Some(facts.file_scopes_digest.clone()),
        };
        let capability = match &request.capability_id {
            // A Runtime-owned policy (`workspace.create-checkpoint@1`) is
            // the Runtime's alone: no capability a caller names admits it,
            // and the catalog must let the Runtime issue its own — one use,
            // pinned to this exact plan — for whichever tree it names.
            Some(_) if policy == "runtimeCapability" => {
                return Err(refused(
                    "admissionDenied",
                    "caller-supplied capabilities cannot admit a Runtime-owned policy",
                ));
            }
            None if policy == "runtimeCapability" => {
                if !descriptor.default_policy_issuance() {
                    return Err(refused(
                        "admissionDenied",
                        format!("catalog disabled Runtime capability issuance for {reference}"),
                    ));
                }
                capability_policy::issue(
                    authority.capabilities,
                    descriptor,
                    &query,
                    false,
                    &self.clock()?,
                )
                .map_err(|failure| match failure {
                    IssueFailure::Refused(message) => refused("admissionDenied", message),
                    IssueFailure::Unreadable => uncertain(),
                })?
            }
            // A primary tree is never admitted under a named capability here:
            // the only one it may run under is a person's, which this Runtime
            // neither issues nor honours.
            Some(named) if !facts.isolated_task_copy => {
                return Err(refused(
                    "admissionDenied",
                    format!(
                        "capability denied [denial:capabilityNotFound]: {}",
                        CapabilityStoreError::NotFound(named.clone()).swift()
                    ),
                ));
            }
            Some(named) => named.clone(),
            None if parsed == Effect::DeviceMutation
                && policy == "standingCapability"
                && crate::workspace_profile::automatic_issuance_permitted(
                    descriptor,
                    Some(&facts),
                ) =>
            {
                capability_policy::issue(
                    authority.capabilities,
                    descriptor,
                    &query,
                    false,
                    &self.clock()?,
                )
                .map_err(|failure| match failure {
                    IssueFailure::Refused(message) => refused("admissionDenied", message),
                    IssueFailure::Unreadable => uncertain(),
                })?
            }
            None => {
                return Err(refused(
                    "admissionDenied",
                    format!("effect {effect} requires an explicit runtime capability"),
                ));
            }
        };
        authority
            .capabilities
            .validate_new_execution(&capability, &query, &self.clock()?)
            .map_err(|error| {
                refused(
                    "admissionDenied",
                    format!(
                        "capability denied [denial:{}]: {}",
                        denial_code(&error),
                        error.swift()
                    ),
                )
            })?;
        Ok(capability)
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
