//! Controlled retry subphases remain under the parent's durable flash-partitions
//! intent, exact program digest, consumed capability and one absolute deadline.
use super::*;
use crate::flash_recommission_retry as retry;
use crate::job_owner::arkforge_job_state::execution_value;
use crate::job_owner::flash_recommission::{Allocation, clock_millis};
use arkdeck_provider_arkforge::{FullReadback, validate_recommission_readback};
use std::time::Duration;

impl FlashRunner<'_> {
    pub(super) fn controlled_retry_allocation(&self, run: &Run) -> Option<Allocation> {
        run.record
            .admission_evidence()
            .and_then(RecoveryContext::from_evidence)
            .and_then(|context| context.recommission)
            .filter(|allocation| allocation.controlled_retry.is_some())
    }

    pub(super) fn prepare_controlled_retry(
        &self,
        run: &Run,
        flash: &FlashExecution<'_>,
        facts: &RockchipFacts,
        resolved: &Resolved,
    ) -> Stepped<Option<retry::Prepared>> {
        let Some(allocation) = self.controlled_retry_allocation(run) else {
            return Ok(None);
        };
        let request = OperationRequest::decode(
            &serde_json::to_vec(&run.record.request).map_err(|_| Stop::Refused(uncertain()))?,
        )
        .map_err(|_| Stop::Refused(uncertain()))?;
        let owner = self
            .runner
            .mutation
            .ok_or_else(|| Stop::Refused(uncertain()))?;
        let planner = JobPlanner {
            artifacts: Some(self.runner.artifacts),
            imports: self.runner.imports,
            analyzer: None,
            state_root: owner.state_root,
            hdc: None,
            workspace: None,
        };
        let context = crate::flash_maintenance::context(flash.planning).map_err(Stop::Failed)?;
        let prepared = retry::prepare(&context, &planner, &request, facts, &resolved.leased)
            .map_err(Stop::Failed)?;
        prepared
            .program
            .require_allocation(&allocation, &request)
            .map_err(Stop::Failed)?;
        Ok(Some(prepared))
    }

    fn retry_budget(&self, run: &Run, allocation: &Allocation, deadline: Instant) -> Stepped<()> {
        if Instant::now() >= deadline {
            return Err(Stop::Unknown(
                "recommission.independentBudgetExpired".into(),
            ));
        }
        self.runner
            .jobs
            .check_active_recommission(allocation, &run.clock()?)
            .map_err(Stop::Unknown)
    }

    fn measure_retry_partition(
        &self,
        run: &Run,
        context: &crate::flash_maintenance::MaintenanceContext,
        allocation: &Allocation,
        effect: &arkdeck_provider_arkforge::maintenance::Effect,
        nonce: Option<&str>,
        deadline: Instant,
    ) -> Stepped<(retry::Measurement, Option<retry::PrebootProof>)> {
        self.retry_budget(run, allocation, deadline)?;
        let before = retry::observe(context, allocation, deadline).map_err(Stop::Unknown)?;
        let (hash, preboot) = context
            .reads
            .recommission_read(&before.execution_connect_key, effect, nonce, deadline)
            .map_err(Stop::Unknown)?;
        self.retry_budget(run, allocation, deadline)?;
        retry::observe(context, allocation, deadline).map_err(Stop::Unknown)?;
        if hash != effect.content_sha256
            || preboot.is_some() != nonce.is_some()
            || preboot.as_ref().is_some_and(|proof| proof.digest != hash)
        {
            return Err(Stop::Unknown(
                "recommission.independentReadbackMismatch".into(),
            ));
        }
        let proof = preboot.map(|proof| retry::PrebootProof {
            nonce: nonce.unwrap_or_default().into(),
            boot_id_sha256: proof.boot_id_sha256,
            storage_cid_sha256: proof.storage_cid_sha256,
        });
        Ok((
            retry::Measurement {
                target: effect.target.clone(),
                range_start: effect.range_start,
                range_length: effect.range_length,
                sha256: hash,
            },
            proof,
        ))
    }

    pub(super) fn complete_controlled_retry(
        &self,
        run: &mut Run,
        flash: &FlashExecution<'_>,
        prepared: retry::Prepared,
        execution: &Execution,
        binding: &DeviceBinding,
    ) -> Stepped<()> {
        let allocation = self
            .controlled_retry_allocation(run)
            .ok_or_else(|| Stop::Refused(uncertain()))?;
        let now = clock_millis(&run.clock()?)
            .ok_or_else(|| Stop::Unknown("recommission.clockUnavailable".into()))?;
        let remaining = allocation
            .expires_at_epoch_ms
            .checked_sub(now)
            .filter(|value| *value > 0)
            .ok_or_else(|| Stop::Unknown("recommission.independentBudgetExpired".into()))?;
        let deadline = Instant::now() + Duration::from_millis(remaining);
        let context = crate::flash_maintenance::context(flash.planning).map_err(Stop::Unknown)?;
        self.retry_budget(run, &allocation, deadline)?;
        let source = flash
            .lane
            .maintenance_source(execution)
            .map_err(Stop::Unknown)?;
        if source.plan != prepared.primary {
            return Err(Stop::Unknown("recommission.primaryPlanDrifted".into()));
        }
        // Fetch the bounded RAM report before doing the larger static reads.
        let mut effects: Vec<_> = source.plan.persistent_effects.iter().collect();
        effects.sort_by_key(|effect| effect.target != "userdata");
        let mut primary_reads = Vec::new();
        let mut preboot = None;
        for effect in effects {
            let nonce = (effect.target == "userdata").then(|| prepared.program.nonce());
            let (measurement, report) =
                self.measure_retry_partition(run, &context, &allocation, effect, nonce, deadline)?;
            primary_reads.push(measurement);
            if report.is_some() {
                preboot = report;
            }
        }
        let primary_hashes: Vec<FullReadback> = primary_reads
            .iter()
            .map(retry::Measurement::readback)
            .collect();
        validate_recommission_readback(execution, &source, &primary_hashes, false)
            .map_err(Stop::Unknown)?;
        let preboot =
            preboot.ok_or_else(|| Stop::Unknown("recommission.prebootReadbackMissing".into()))?;
        retry::write_once(self.runner.jobs, &run.record.job_id, "recommission-primary-readback.json", &json!({
            "schema": "arkdeck.recommission-primary-readback/v1", "programSHA256": prepared.program.sha256(),
            "execution": execution_value(execution), "measurements": primary_reads, "preboot": preboot,
        })).map_err(Stop::Unknown)?;
        self.retry_budget(run, &allocation, deadline)?;
        let fresh = retry::observe(&context, &allocation, deadline).map_err(Stop::Unknown)?;
        if !self
            .runner
            .artifacts
            .payload_matches(&prepared.restoration_lease)
        {
            return Err(Stop::Unknown(
                "recommission.restorationArtifactChanged".into(),
            ));
        }
        flash
            .lane
            .recommission_quiescent(execution)
            .map_err(Stop::Unknown)?;
        let child = format!("{}-restore", run.record.job_id);
        // No second capability/epoch is issued. This exact child plan was pinned
        // into the parent's materialized digest before its allocation existed.
        retry::write_once(self.runner.jobs, &run.record.job_id, "recommission-restoration-intent.json", &json!({
            "schema": "arkdeck.recommission-restoration-intent/v1", "childId": child,
            "allocationSHA256": allocation.sha256(), "programSHA256": prepared.program.sha256(),
            "planSHA256": prepared.restoration.plan_sha256, "artifactSHA256": prepared.restoration_artifact.sha256,
        })).map_err(Stop::Unknown)?;
        let mut binding = binding.clone();
        binding.connect_key = fresh.execution_connect_key;
        self.retry_budget(run, &allocation, deadline)?;
        let restored = flash
            .lane
            .prepare_restoration(
                &child,
                &prepared.restoration,
                &prepared.restoration_artifact,
                &binding,
            )
            .map_err(|failure| {
                Stop::Unknown(format!("recommission.restorationPrepare: {failure:?}"))
            })?;
        correlated(
            &restored,
            &child,
            &prepared.restoration_artifact,
            &binding,
            "primaryFlash",
            flash.lane.toolchain_sha256(),
        )
        .map_err(|_| Stop::Unknown("recommission.restorationCorrelationMismatch".into()))?;
        let mut restoration_state = ArkForgeJobState {
            execution: Some(restored.clone()),
            completion: None,
        };
        if restored.plan_id != prepared.restoration.plan_id
            || restored.plan_sha256 != prepared.restoration.plan_sha256
        {
            return Err(Stop::Unknown(
                "recommission.preparedRestorationPlanDrifted".into(),
            ));
        }
        retry::write_once(
            self.runner.jobs,
            &run.record.job_id,
            "recommission-restoration-execution.json",
            &restoration_state.value(),
        )
        .map_err(Stop::Unknown)?;
        self.retry_budget(run, &allocation, deadline)?;
        let receipt = flash
            .lane
            .perform_restoration(
                &restored,
                &prepared.restoration_artifact,
                &binding,
                deadline,
            )
            .map_err(|failure| {
                Stop::Unknown(format!("recommission.restorationIncomplete: {failure:?}"))
            })?;
        if !validate_completion(&receipt, Some(&restored)) {
            return Err(Stop::Unknown(
                "recommission.restorationPostflightMissing".into(),
            ));
        }
        restoration_state.completion = Some(receipt);
        retry::write_once(
            self.runner.jobs,
            &run.record.job_id,
            "recommission-restoration-completion.json",
            &restoration_state.value(),
        )
        .map_err(Stop::Unknown)?;
        let (restoration_read, _) = self.measure_retry_partition(
            run,
            &context,
            &allocation,
            &prepared.restoration.persistent_effects[0],
            None,
            deadline,
        )?;
        let restored_source = flash
            .lane
            .maintenance_source(&restored)
            .map_err(Stop::Unknown)?;
        if restored_source.plan != prepared.restoration {
            return Err(Stop::Unknown("recommission.restorationPlanDrifted".into()));
        }
        validate_recommission_readback(
            &restored,
            &restored_source,
            &[restoration_read.readback()],
            true,
        )
        .map_err(Stop::Unknown)?;
        self.retry_budget(run, &allocation, deadline)?;
        retry::observe(&context, &allocation, deadline).map_err(Stop::Unknown)?;
        let completed_at_epoch_ms = clock_millis(&run.clock()?)
            .ok_or_else(|| Stop::Unknown("recommission.clockUnavailable".into()))?;
        let proof = retry::Proof {
            schema: "arkdeck.recommission-full-readback/v1".into(),
            program_sha256: prepared.program.sha256(),
            allocation_sha256: allocation.sha256(),
            primary_execution: execution_value(execution),
            primary_reads,
            preboot,
            restoration_state: restoration_state.value(),
            restoration_read,
            completed_at_epoch_ms,
        };
        retry::write_once(
            self.runner.jobs,
            &run.record.job_id,
            retry::PROOF,
            &json!(proof),
        )
        .map_err(Stop::Unknown)?;
        self.runner
            .jobs
            .require_controlled_retry_proof(&run.record, execution, flash.lane)
            .map_err(Stop::Unknown)?;
        run.record.timeline.push("controlled retry independently verified all nine complete ranges and the restored original 4 MiB ramdisk".into());
        run.persist(self.runner.jobs)?;
        Ok(())
    }
}
