//! Runtime-owned capability consumption immediately before a device mutation
//! (a pointer gesture, or a port rule's change).
//! Admission alone is not authority to dispatch: the complete typed plan and
//! binding are re-established, then the reserved use and its correlated Job
//! evidence become durable before the step's write-ahead intent.
use crate::capability_policy;
use crate::capability_store::{CapabilityQuery, Effect, UseOutcome};
use crate::device_facts::{self, DeviceFacts};
use crate::job_admission::MutationAuthority;
use crate::job_plan::JobPlanner;
use crate::job_run::{JobRunner, Run, RunRefusal, uncertain};
use crate::operation_catalog::CatalogOperation;
use crate::operation_request::OperationRequest;
use arkdeck_contract::sha256_hex;
use serde_json::json;
use std::path::Path;

/// The same Runtime owners used at admission, plus the source of the fresh plan.
#[derive(Clone, Copy)]
pub struct MutationExecution<'a> {
    pub authority: MutationAuthority<'a>,
    pub state_root: &'a Path,
}

pub(crate) enum MutationConsumption {
    Consumed,
    Cancelled,
    PersistenceUncertain,
}

impl JobRunner<'_> {
    pub(crate) fn consume_mutation_authority(
        &self,
        run: &mut Run,
        descriptor: &CatalogOperation,
        facts: &DeviceFacts,
    ) -> Result<MutationConsumption, String> {
        let reject = |detail: String| format!("authorizationRequired: {detail}");
        let owner = self
            .mutation
            .ok_or_else(|| reject("Runtime mutation owner is unavailable".into()))?;
        let _reservation_guard = owner
            .authority
            .holds
            .mutation_reservation_guard()
            .map_err(&reject)?;
        let dispatcher = self
            .hdc
            .ok_or_else(|| reject("Runtime HDC owner unavailable".into()))?;
        if !dispatcher.dispatch.mutation_identity_current() {
            return Err(reject("fresh tool identity cannot be proved".into()));
        }
        owner
            .authority
            .require_state(self.jobs)
            .map_err(|e| reject(e.message))?;
        let request = OperationRequest::decode(
            &serde_json::to_vec(&run.record.request).map_err(|e| reject(e.to_string()))?,
        )
        .map_err(|_| reject("the persisted request is unreadable".into()))?;
        let capability = request
            .capability_id
            .as_deref()
            .ok_or_else(|| reject("mutation has no runtime capability reference".into()))?;
        device_facts::validate(facts, &request.target_id, request.expected_binding_revision)
            .map_err(|s| reject(s.into()))?;
        let planner = JobPlanner {
            imports: self.imports,
            artifacts: Some(self.artifacts),
            analyzer: self.analyzer,
            state_root: owner.state_root,
            hdc: self.hdc,
        };
        let fresh = planner
            .materialized(&request, descriptor)
            .map_err(|_| reject("fresh typed plan could not be materialized".into()))?;
        if Some(fresh.digest.as_str()) != run.record.materialized_plan()
            || fresh.identity.as_deref() != run.record.materialized_identity()
            || fresh.binding_revision != run.record.materialized_binding()
            || Some(facts.identity.as_str()) != fresh.identity.as_deref()
            || Some(facts.binding_revision) != fresh.binding_revision
        {
            return Err(reject(
                "fresh typed plan, target or binding drifted before dispatch".into(),
            ));
        }
        let query = CapabilityQuery {
            operation_id: descriptor.id().into(),
            operation_version: descriptor.version(),
            effect: Effect::DeviceMutation,
            target_stable_identity_sha256: fresh.identity,
            target_binding_revision: fresh.binding_revision,
            plan_digest: Some(fresh.digest.clone()),
            inputs: capability_policy::subject(descriptor, &request.inputs),
            artifact_facts: fresh.artifact_facts.clone(),
            workspace_identity_sha256: None,
            workspace_revision: None,
            workspace_file_scopes_digest: None,
        };
        if run.record.admission_evidence().is_some() {
            // This runner never resumes a dispatched Job. A persisted consumption
            // without a new run boundary must not become a second dispatch.
            return Err(reject(
                "persisted mutation evidence cannot be replayed".into(),
            ));
        }
        let store = owner.authority.capabilities;
        if let Some(blocker) = store
            .unresolved_use(
                &facts.identity,
                facts.binding_revision,
                Some((&request.idempotency_key, &run.record.job_id)),
            )
            .map_err(|e| reject(e.swift()))?
        {
            return Err(reject(blocker.blocker().swift()));
        }
        let status = store
            .handle(
                "capability.inspect",
                json!({"capabilityId":capability}).as_object().unwrap(),
            )
            .map_err(|_| reject("capability status could not be read".into()))?;
        let scoped = capability_policy::session_scoped(descriptor, &request.inputs);
        if status["capability"]["issuer"]["kind"] == "runtimeDefaultPolicy" {
            let fingerprint = capability_policy::policy_fingerprint(&query, scoped);
            if !capability.starts_with(&format!("CAP-RT-POLICY-{}-G", &fingerprint[..40])) {
                return Err(reject("Runtime policy fingerprint drifted".into()));
            }
        }
        owner
            .authority
            .require_state(self.jobs)
            .map_err(|e| reject(e.message))?;
        if !dispatcher.dispatch.mutation_identity_current() {
            return Err(reject(
                "fresh tool identity drifted before consumption".into(),
            ));
        }
        let now = run
            .clock()
            .map_err(|_| reject("Runtime clock unavailable".into()))?;
        if self
            .cancellation
            .is_some_and(crate::job_cancel::RunCancellation::pending)
        {
            return Ok(MutationConsumption::Cancelled);
        }
        let step_set_digest = crate::job_plan::step_set_digest(descriptor, &request.inputs)
            .map_err(|_| reject("complete step set could not be materialized".into()))?;
        let consumed = store
            .consume(
                capability,
                &request.idempotency_key,
                Some(&run.record.job_id),
                &query,
                &now,
            )
            .map_err(|e| reject(e.swift()))?;
        let mut evidence = json!({"kind":"runtimeCapability", "reference":capability,
            "admittedAtUTC":consumed.consumed_at_utc, "validUntilUTC":status["capability"]["expiresAtUTC"],
            "consumptionFingerprintSHA256":consumed.query_fingerprint_sha256,
            "runtimeCapabilityCorrelation":{"reservationID":consumed.reservation_id, "useOrdinal":consumed.ordinal,
                "planDigestSHA256":fresh.digest, "stepSetDigestSHA256":step_set_digest,
                "targetBindingDigestSHA256":sha256_hex(format!("{}\n{}",facts.identity,facts.binding_revision).as_bytes())}});
        if let Some(digest) = fresh.artifact_facts.get("artifactSha256") {
            evidence["runtimeCapabilityCorrelation"]["artifactSHA256"] = json!(digest);
        }
        run.record.set_admission_evidence(evidence);
        run.record
            .timeline
            .push("capability consumed before first mutation".into());
        if run.persist(self.jobs).is_err() {
            // A reservation may already be durable. Do not retry the Job write,
            // invent a terminal receipt, or let another Job bypass pending use.
            return Ok(MutationConsumption::PersistenceUncertain);
        }
        Ok(MutationConsumption::Consumed)
    }

    pub(crate) fn settle_mutation(&self, run: &Run, outcome: UseOutcome) -> Result<(), RunRefusal> {
        let Some(evidence) = run.record.admission_evidence() else {
            return Ok(());
        };
        if evidence["kind"] != "runtimeCapability" {
            return Ok(());
        }
        let owner = self.mutation.ok_or_else(uncertain)?;
        owner
            .authority
            .capabilities
            .record_outcome(
                evidence["reference"].as_str().ok_or_else(uncertain)?,
                run.record.request["idempotencyKey"]
                    .as_str()
                    .ok_or_else(uncertain)?,
                &run.record.job_id,
                outcome,
                &run.record.state,
                &run.clock()?,
            )
            .map_err(|_| uncertain())
    }
}
