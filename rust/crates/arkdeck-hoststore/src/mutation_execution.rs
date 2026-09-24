//! Runtime-owned capability consumption immediately before a device mutation
//! (a pointer gesture, a port rule's change, or each of a debug HAP's).
//! Admission alone is not authority to dispatch: the complete typed plan and
//! binding are re-established, then the reserved use and its correlated Job
//! evidence become durable before the step's write-ahead intent.
//!
//! A Job consumes one use for its whole run, before its first mutation.
//! Swift `consumeCapabilityBeforeMutation` lets a later mutation of the same
//! Job proceed under that use ("persisted evidence": this Job already owns
//! it) once every fresh check has passed again: the mutation state, the whole
//! typed plan materialized again against fresh Target facts, and the evidence
//! naming exactly the Job's capability. A debug HAP's compensation, run while
//! the Job is `finalizing`, also proves that use is still this Job's own,
//! unsettled, for the same query and still authorized (`validateContinuation`),
//! and correlated as it was consumed. This runner continues only a use it
//! consumed itself, or — for a Job resumed at its confirmed safe boundary, a
//! Job a restart left `running` with nothing outstanding, or a debug HAP's
//! failure finalization continued — the use the Job's record names once the
//! capability store proves it is that Job's own and still unsettled (a
//! stricter check than Swift's, which reads the record alone). Evidence on a
//! record of a Job not resumed is never continued, and no resumed Job
//! consumes a second use (ADR-0009, L.1 item 13).
use crate::capability_policy;
use crate::capability_store::{CapabilityQuery, Effect, UseOutcome};
use crate::device_facts::{self, DeviceFacts};
use crate::job_admission::MutationAuthority;
use crate::job_plan::JobPlanner;
use crate::job_record::JobRecord;
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
    /// The Job's one use was consumed and its evidence is durable.
    Consumed,
    /// The Job already holds the use this run consumed; nothing new is
    /// consumed.
    Held,
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
        // Evidence this run did not consume is never continued, whatever it
        // names: a persisted consumption without this run's own boundary must
        // not become a second dispatch.
        let persisted = run.record.admission_evidence().cloned();
        if let Some(evidence) = &persisted {
            if run.consumed.as_ref() != Some(evidence) {
                return Err(reject(
                    "persisted mutation evidence cannot be replayed".into(),
                ));
            }
            // Swift: the Job's own use of the capability it runs under.
            if evidence["kind"] != "runtimeCapability"
                || evidence["reference"] != run.record.request["authorization"]["capabilityId"]
            {
                return Err(reject(
                    "persisted admission evidence does not match the mutation".into(),
                ));
            }
        }
        let FreshUse {
            request,
            capability,
            fresh,
            query,
        } = self.fresh_use(&owner, &run.record, descriptor, facts)?;
        let capability = capability.as_str();
        let store = owner.authority.capabilities;
        if let Some(evidence) = persisted {
            // Swift's persisted-evidence arm: the state proven once more at
            // the boundary, and no second use.
            owner
                .authority
                .require_state(self.jobs)
                .map_err(|e| reject(e.message))?;
            if !dispatcher.dispatch.mutation_identity_current() {
                return Err(reject(
                    "fresh tool identity drifted before consumption".into(),
                ));
            }
            // The failure lane dropped any request to cancel before it began
            // (Swift `performDebugHAPFailureFinalization`); elsewhere a request
            // that has reached the run stops it here.
            if run.record.state != "finalizing"
                && self
                    .cancellation
                    .is_some_and(crate::job_cancel::RunCancellation::pending)
            {
                return Ok(MutationConsumption::Cancelled);
            }
            // A debug HAP's compensation continues under the use its Job
            // consumed; `reconciling`, Swift's other arm, is recovery.
            if descriptor.reference() == "debug.hap@1" && run.record.state == "finalizing" {
                let now = run
                    .clock()
                    .map_err(|_| reject("Runtime clock unavailable".into()))?;
                self.continuation_correlates(
                    &run.record,
                    descriptor,
                    &evidence,
                    capability,
                    &request,
                    &query,
                    &now,
                )?;
            }
            return Ok(MutationConsumption::Held);
        }
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
        run.record.set_admission_evidence(evidence.clone());
        run.record
            .timeline
            .push("capability consumed before first mutation".into());
        if run.persist(self.jobs).is_err() {
            // A reservation may already be durable. Do not retry the Job write,
            // invent a terminal receipt, or let another Job bypass pending use.
            return Ok(MutationConsumption::PersistenceUncertain);
        }
        run.consumed = Some(evidence);
        Ok(MutationConsumption::Consumed)
    }

    /// Swift `consumeCapabilityBeforeMutation` for a workspace mutation: the
    /// complete typed plan materialized again for the authorization envelope
    /// and equal to the one admitted, the tree the request names measured
    /// again — so a tree that moved since admission is refused here rather
    /// than changed anyway — the capability's policy identity recomputed, and
    /// the Job's one use consumed and made durable with its correlated
    /// evidence before the step's write-ahead intent can exist.
    pub(crate) fn consume_workspace_authority(
        &self,
        run: &mut Run,
        descriptor: &CatalogOperation,
        workspace: &crate::WorkspaceComposition,
        leased: Option<&crate::workspace_composition::LeasedPatch>,
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
        owner
            .authority
            .require_state(self.jobs)
            .map_err(|e| reject(e.message))?;
        // A workspace mutation consumes once, from its admitted boundary:
        // evidence this run did not consume is never continued.
        if let Some(evidence) = run.record.admission_evidence() {
            if run.consumed.as_ref() == Some(evidence) {
                return Ok(MutationConsumption::Held);
            }
            return Err(reject(
                "persisted mutation evidence cannot be replayed".into(),
            ));
        }
        let request = OperationRequest::decode(
            &serde_json::to_vec(&run.record.request).map_err(|e| reject(e.to_string()))?,
        )
        .map_err(|_| reject("the persisted request is unreadable".into()))?;
        let capability = request
            .capability_id
            .clone()
            .ok_or_else(|| reject("mutation has no runtime capability reference".into()))?;
        let Some(plan_digest) = run
            .record
            .materialized_plan()
            .filter(|digest| {
                digest.len() == 64
                    && digest
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            })
            .map(str::to_owned)
        else {
            return Err(reject(
                "materialized plan or verified target binding is absent or drifted".into(),
            ));
        };
        let planner = JobPlanner {
            imports: self.imports,
            artifacts: Some(self.artifacts),
            analyzer: self.analyzer,
            state_root: owner.state_root,
            hdc: None,
            workspace: Some(workspace),
        };
        let fresh = planner
            .materialized(&request, descriptor)
            .map_err(|refusal| {
                reject(format!(
                    "fresh typed plan could not be materialized: {}",
                    refusal.message
                ))
            })?;
        if fresh.digest != plan_digest
            || fresh.identity.as_deref() != run.record.materialized_identity()
            || fresh.binding_revision != run.record.materialized_binding()
        {
            return Err(reject(
                "fresh typed plan, target or binding drifted before dispatch".into(),
            ));
        }
        drop(fresh);
        let artifact_facts: std::collections::BTreeMap<String, String> = leased
            .map(|leased| {
                std::collections::BTreeMap::from([
                    ("artifactId".to_owned(), leased.artifact_id.clone()),
                    ("artifactSha256".to_owned(), leased.sha256.clone()),
                    (
                        "artifactByteCount".to_owned(),
                        leased.byte_count.to_string(),
                    ),
                ])
            })
            .unwrap_or_default();
        let facts = workspace
            .authorization_facts(&request.inputs)
            .map_err(|error| {
                reject(format!(
                    "no workspace subject to authorize this mutation against: {error}"
                ))
            })?;
        let query = CapabilityQuery {
            operation_id: descriptor.id().into(),
            operation_version: descriptor.version(),
            effect: Effect::DeviceMutation,
            target_stable_identity_sha256: None,
            target_binding_revision: None,
            plan_digest: Some(plan_digest.clone()),
            inputs: request.inputs.clone(),
            artifact_facts: artifact_facts.clone(),
            workspace_identity_sha256: Some(facts.identity_sha256),
            workspace_revision: Some(facts.revision),
            workspace_file_scopes_digest: Some(facts.file_scopes_digest),
        };
        let store = owner.authority.capabilities;
        let status = store
            .handle(
                "capability.inspect",
                json!({"capabilityId": capability}).as_object().unwrap(),
            )
            .map_err(|_| reject("capability status could not be read".into()))?;
        if status["capability"]["issuer"]["kind"] == "runtimeDefaultPolicy" {
            let fingerprint = capability_policy::policy_fingerprint(&query, false);
            if !capability.starts_with(&format!("CAP-RT-POLICY-{}-G", &fingerprint[..40])) {
                return Err("completeOverwriteRecovery.freshProofDrifted".into());
            }
        }
        if self
            .cancellation
            .is_some_and(crate::job_cancel::RunCancellation::pending)
        {
            return Ok(MutationConsumption::Cancelled);
        }
        owner
            .authority
            .require_state(self.jobs)
            .map_err(|e| reject(e.message))?;
        let now = run
            .clock()
            .map_err(|_| reject("Runtime clock unavailable".into()))?;
        let step_set_digest = crate::job_plan::step_set_digest(descriptor, &request.inputs)
            .map_err(|_| reject("complete step set could not be materialized".into()))?;
        let consumed = store
            .consume(
                &capability,
                &request.idempotency_key,
                Some(&run.record.job_id),
                &query,
                &now,
            )
            .map_err(|e| reject(format!("capability denied before mutation: {}", e.swift())))?;
        let mut evidence = json!({"kind":"runtimeCapability", "reference":capability,
            "admittedAtUTC":consumed.consumed_at_utc, "validUntilUTC":status["capability"]["expiresAtUTC"],
            "consumptionFingerprintSHA256":consumed.query_fingerprint_sha256,
            "runtimeCapabilityCorrelation":{"reservationID":consumed.reservation_id, "useOrdinal":consumed.ordinal,
                "planDigestSHA256":plan_digest, "stepSetDigestSHA256":step_set_digest,
                // A workspace subject names no device and no binding.
                "targetBindingDigestSHA256":sha256_hex(b"-\n-")}});
        if let Some(digest) = artifact_facts.get("artifactSha256") {
            evidence["runtimeCapabilityCorrelation"]["artifactSHA256"] = json!(digest);
        }
        run.record.set_admission_evidence(evidence.clone());
        run.record
            .timeline
            .push("capability consumed before first mutation".into());
        if run.persist(self.jobs).is_err() {
            return Ok(MutationConsumption::PersistenceUncertain);
        }
        run.consumed = Some(evidence);
        Ok(MutationConsumption::Consumed)
    }

    /// A resumed Job takes over the use its record says it consumed (Swift's
    /// resident Job owns it): the record's `runtimeCapability` evidence must
    /// name the capability the request names, and the capability store must
    /// hold that very use — this reservation, this Job, the receipt the
    /// evidence correlates — still unsettled. Then the run continues under it
    /// (Swift's persisted-evidence arm, every fresh check repeated at each
    /// mutation) and settles it; nothing new is consumed. A record without
    /// such evidence has consumed nothing, and its run consumes as a first
    /// run does. The refusal is the reason nothing was dispatched.
    pub(crate) fn take_over_held_use(&self, run: &mut Run) -> Result<(), String> {
        let Some(evidence) = run
            .record
            .admission_evidence()
            .filter(|evidence| evidence["kind"] == "runtimeCapability")
            .cloned()
        else {
            return Ok(());
        };
        let refused = |detail: &str| {
            format!(
                "job {}'s capability use {detail}; the Rust Runtime does not continue it and \
                 nothing was dispatched",
                run.record.job_id
            )
        };
        let (Some(capability), Some(reservation)) = (
            evidence["reference"].as_str().filter(|reference| {
                run.record.request["authorization"]["capabilityId"] == *reference
            }),
            run.record.request["idempotencyKey"].as_str(),
        ) else {
            return Err(refused("is not the one its request names"));
        };
        let Some(owner) = self.mutation else {
            return Err(refused(
                "cannot be proved without the Runtime mutation owner",
            ));
        };
        let held = owner
            .authority
            .capabilities
            .unsettled_use(capability, reservation, &run.record.job_id)
            .map_err(|error| refused(&format!("cannot be read: {}", error.swift())))?;
        let correlation = &evidence["runtimeCapabilityCorrelation"];
        let held = held.is_some_and(|held| {
            evidence["consumptionFingerprintSHA256"] == held.query_fingerprint_sha256.as_str()
                && correlation["useOrdinal"].as_i64() == Some(held.ordinal)
                && correlation["reservationID"] == held.reservation_id.as_str()
        });
        if !held {
            return Err(refused("is not an unsettled use the store holds for it"));
        };
        run.consumed = Some(evidence);
        Ok(())
    }

    /// Swift `recordCapabilityOutcome` once the Job is terminal or parked:
    /// the use this run consumed is settled with the Job's state. A run that
    /// consumed none settles none, whatever evidence its record carries.
    pub(crate) fn settle_mutation(&self, run: &Run, outcome: UseOutcome) -> Result<(), RunRefusal> {
        let Some(evidence) = run.consumed.as_ref() else {
            return Ok(());
        };
        if run.record.admission_evidence() != Some(evidence)
            || evidence["kind"] != "runtimeCapability"
        {
            return Err(uncertain());
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

/// What every use of a Job's capability proves first, whether a run consumes
/// it now or the Job already holds it: the persisted request names the
/// capability, the Target facts hold for it, and the whole typed plan
/// materialized again against them is the plan, identity and binding the
/// Job's admission materialized. The query is what the store judges.
struct FreshUse<'a> {
    request: OperationRequest,
    capability: String,
    fresh: crate::job_plan::Materialized<'a>,
    query: CapabilityQuery,
}

impl<'a> JobRunner<'a> {
    fn fresh_use(
        &self,
        owner: &MutationExecution<'a>,
        record: &JobRecord,
        descriptor: &CatalogOperation,
        facts: &DeviceFacts,
    ) -> Result<FreshUse<'a>, String> {
        let reject = |detail: String| format!("authorizationRequired: {detail}");
        owner
            .authority
            .require_state(self.jobs)
            .map_err(|e| reject(e.message))?;
        let request = OperationRequest::decode(
            &serde_json::to_vec(&record.request).map_err(|e| reject(e.to_string()))?,
        )
        .map_err(|_| reject("the persisted request is unreadable".into()))?;
        let capability = request
            .capability_id
            .clone()
            .ok_or_else(|| reject("mutation has no runtime capability reference".into()))?;
        device_facts::validate(facts, &request.target_id, request.expected_binding_revision)
            .map_err(|s| reject(s.into()))?;
        let planner = JobPlanner {
            imports: self.imports,
            artifacts: Some(self.artifacts),
            analyzer: self.analyzer,
            state_root: owner.state_root,
            hdc: self.hdc,
            workspace: None,
        };
        let fresh = planner
            .materialized(&request, descriptor)
            .map_err(|_| reject("fresh typed plan could not be materialized".into()))?;
        if Some(fresh.digest.as_str()) != record.materialized_plan()
            || fresh.identity.as_deref() != record.materialized_identity()
            || fresh.binding_revision != record.materialized_binding()
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
            target_stable_identity_sha256: fresh.identity.clone(),
            target_binding_revision: fresh.binding_revision,
            plan_digest: Some(fresh.digest.clone()),
            inputs: capability_policy::subject(descriptor, &request.inputs),
            artifact_facts: fresh.artifact_facts.clone(),
            workspace_identity_sha256: None,
            workspace_revision: None,
            workspace_file_scopes_digest: None,
        };
        Ok(FreshUse {
            request,
            capability,
            fresh,
            query,
        })
    }

    /// Swift `validateContinuation` for a debug HAP compensation: the use is
    /// still the Job's own, unsettled, for the same query and still
    /// authorized, and correlated as it was consumed.
    #[allow(clippy::too_many_arguments)]
    fn continuation_correlates(
        &self,
        record: &JobRecord,
        descriptor: &CatalogOperation,
        evidence: &serde_json::Value,
        capability: &str,
        request: &OperationRequest,
        query: &CapabilityQuery,
        now: &str,
    ) -> Result<(), String> {
        let reject = |detail: String| format!("authorizationRequired: {detail}");
        let store = self
            .mutation
            .ok_or_else(|| reject("Runtime mutation owner is unavailable".into()))?
            .authority
            .capabilities;
        let receipt = store
            .validate_continuation(
                capability,
                &request.idempotency_key,
                &record.job_id,
                query,
                now,
            )
            .map_err(|e| reject(format!("capability denied before mutation: {}", e.swift())))?;
        let correlation = &evidence["runtimeCapabilityCorrelation"];
        let step_set = crate::job_plan::step_set_digest(descriptor, &request.inputs)
            .map_err(|_| reject("complete step set could not be materialized".into()))?;
        if evidence["consumptionFingerprintSHA256"] != receipt.query_fingerprint_sha256.as_str()
            || correlation["useOrdinal"].as_i64() != Some(receipt.ordinal)
            || correlation["reservationID"] != receipt.reservation_id.as_str()
            || correlation["stepSetDigestSHA256"] != step_set.as_str()
        {
            return Err("compensation capability correlation drifted".into());
        }
        Ok(())
    }

    /// Swift `consumeCapabilityBeforeMutation`'s persisted-evidence arm for a
    /// Job no run holds: a cleanup debt's retry (`continueCleanupDebt`)
    /// dispatches under the use the Job consumed once every fresh check has
    /// passed again, and consumes nothing. A debug HAP still finalizing or
    /// reconciling also proves the use is still its own. Swift would consume
    /// a new use for a Job without that evidence, which no Rust runner leaves
    /// owing a debt; it is refused here.
    pub(crate) fn continue_held_use(
        &self,
        record: &JobRecord,
        descriptor: &CatalogOperation,
        facts: &DeviceFacts,
        now: &str,
    ) -> Result<(), String> {
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
        let Some(evidence) = record.admission_evidence().cloned() else {
            return Err(reject(
                "the Job holds no persisted mutation evidence".into(),
            ));
        };
        if evidence["kind"] != "runtimeCapability"
            || evidence["reference"] != record.request["authorization"]["capabilityId"]
        {
            return Err(reject(
                "persisted admission evidence does not match the mutation".into(),
            ));
        }
        let FreshUse {
            request,
            capability,
            query,
            ..
        } = self.fresh_use(&owner, record, descriptor, facts)?;
        owner
            .authority
            .require_state(self.jobs)
            .map_err(|e| reject(e.message))?;
        if !dispatcher.dispatch.mutation_identity_current() {
            return Err(reject(
                "fresh tool identity drifted before consumption".into(),
            ));
        }
        if descriptor.reference() == "debug.hap@1"
            && matches!(record.state.as_str(), "finalizing" | "reconciling")
        {
            self.continuation_correlates(
                record,
                descriptor,
                &evidence,
                &capability,
                &request,
                &query,
                now,
            )?;
        }
        Ok(())
    }
}
