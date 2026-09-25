//! Rust `job.submit` of the ArkForge Flash operations — the canonical
//! `flash.full-restore@1` and its compatibility alias `flash.dayu200` — as
//! Swift `submitOwned` admits them over the Flash composition, in its order:
//!
//! 1. the typed request, its catalog operation and inputs;
//! 2. idempotency, before anything is materialized;
//! 3. the Target binding's provably settled capability outcomes repaired;
//! 4. the Import holds, then the complete plan materialized as `job.plan`
//!    materializes it (`FlashPlanner`), the fresh digest checked against a
//!    reviewed one;
//! 5. `preauthorize`: the Job state, another client's device session, the
//!    catalog's Runtime-owned policy, the provider's execution blocker, a
//!    capability a caller named.
//!
//! Every refusal comes before the durable admission point and dispatches
//! nothing. A request that passes them all is refused too, before any
//! capability is issued: the Runtime's one-use destructive capability and
//! the complete-overwrite admission (DEC-016) are the execution's to issue,
//! and a Flash is admitted only together with the run that consumes it.
use super::*;
use crate::job_plan::{FlashPlanner, FlashPlanning, RockchipFactsPort, is_flash};

/// `job.submit` over the Flash composition: the ArkForge Flash operations
/// are admitted here, every other request by the admitter as before.
pub struct FlashAdmitter<'a> {
    pub admitter: JobAdmitter<'a>,
    /// The Flash composition; without one a Flash request is the admitter's,
    /// which does not materialize it.
    pub flash: Option<&'a FlashPlanning>,
    /// The facts port; none when the daemon composed none.
    pub facts: Option<RockchipFactsPort<'a>>,
}

impl FlashAdmitter<'_> {
    /// The `job.submit` control parameters: exactly one bounded `requestJson`.
    pub fn handle(&self, params: &Map<String, Value>) -> Result<Value, AdmissionRefusal> {
        self.submit(request_json(params)?.as_bytes())
    }

    pub fn submit(&self, request_json: &[u8]) -> Result<Value, AdmissionRefusal> {
        let request = OperationRequest::decode(request_json)
            .map_err(|rejection| refused(rejection.code.wire_code(), rejection.message))?;
        let Some(flash) = self.flash.filter(|_| is_flash(&request.reference())) else {
            return self.admitter.submit(request_json);
        };
        let Some(descriptor) =
            CatalogOperation::lookup(&request.operation_id, request.operation_version)
        else {
            return Err(refused(
                "operationUnavailable",
                format!("operation {} is not in the catalog", request.reference()),
            ));
        };
        JobPlanner::validate_inputs(&request, descriptor)?;
        let admitter = &self.admitter;
        let fingerprint = request.fingerprint();
        match admitter
            .jobs
            .lookup(&request.idempotency_key, &fingerprint)
            .map_err(|_| uncertain())?
        {
            AdmissionVerdict::Duplicate(job_id) => {
                return admitter.duplicate(&job_id, &request, false);
            }
            AdmissionVerdict::Conflict => return Err(conflict()),
            AdmissionVerdict::Admitted => (),
        }
        drop(
            admitter
                .jobs
                .admission_interlock()
                .map_err(interlock_refusal)?,
        );
        let effect = descriptor.effective_effect(&request.inputs);
        if let (Some(revision), Some(authority)) =
            (request.expected_binding_revision, admitter.authority)
        {
            crate::job_lineage_repair::repair_outcome_gaps(
                admitter.jobs,
                authority.capabilities,
                &request.target_id,
                revision,
                admitter.now,
            )
            .map_err(|_| uncertain())?;
        }
        let planner = FlashPlanner {
            planner: admitter.planner,
            flash: Some(flash),
            facts: self.facts,
        };
        // A plan that fails outside the typed preflight — an alias request
        // whose partition plan cannot be converted — fails Swift's submit
        // without the zero-dispatch proof its planner attaches.
        let (materialized, blocker) = planner
            .admission_materialized(flash, &request, descriptor)
            .map_err(|refusal| {
                if refusal.code == "internalError" {
                    uncertain()
                } else {
                    refusal.into()
                }
            })?;
        let _admission = admitter
            .jobs
            .admission_interlock()
            .map_err(interlock_refusal)?;
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
        self.preauthorize(&request, descriptor, &effect, &materialized, blocker)
    }

    /// Swift `preauthorize` for a Flash, up to the Runtime capability it
    /// would issue: every check that can refuse before one exists.
    fn preauthorize(
        &self,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
        effect: &str,
        materialized: &Materialized<'_>,
        blocker: Option<String>,
    ) -> Result<Value, AdmissionRefusal> {
        let admitter = &self.admitter;
        let reference = descriptor.reference();
        let unserved = || {
            refused(
                "rejected",
                format!(
                    "{reference} needs a Runtime capability, which the Rust Runtime does not issue yet"
                ),
            )
        };
        let Some(authority) = admitter.authority else {
            return Err(unserved());
        };
        authority
            .require_state(admitter.jobs)
            .map_err(|error| refused("admissionDenied", error.message))?;
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
                false,
                &admitter.clock()?,
            )
            .map_err(|message| refused("resourceConflict", message))?;
        let Some(policy) = descriptor.authorization.get(effect) else {
            return Err(refused(
                "admissionDenied",
                format!("catalog has no authorization policy for effect {effect}"),
            ));
        };
        if let Some(blocker) = blocker {
            return Err(refused(
                "admissionDenied",
                format!(
                    "provider execution prerequisite blocked before capability issuance: {blocker}"
                ),
            ));
        }
        if materialized.identity.is_none() || materialized.binding_revision.is_none() {
            return Err(refused(
                "admissionDenied",
                "complete-overwrite admission requires stable target identity and binding",
            ));
        }
        // Swift's complete-overwrite admission (DEC-016) reads the
        // superseding recovery epochs under their store's lock first.
        admitter.jobs.recovery_epochs().map_err(|_| uncertain())?;
        if policy == "runtimeCapability" {
            if request.capability_id.is_some() {
                return Err(refused(
                    "admissionDenied",
                    "caller-supplied capabilities cannot admit a Runtime-owned policy",
                ));
            }
            if !descriptor.default_policy_issuance() {
                return Err(refused(
                    "admissionDenied",
                    format!("catalog disabled Runtime capability issuance for {reference}"),
                ));
            }
        }
        Err(unserved())
    }
}
