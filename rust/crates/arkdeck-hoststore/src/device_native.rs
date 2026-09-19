//! Swift's engine around a native library deployment's provider
//! (`deploy.native-library.app-owned@1`): the leased library verified on the
//! host before any device step (`verifyHostInputArtifact`), and a required
//! step's confirmed failure compensated inside the step loop before the Job
//! fails (`compensateNativeLibrary`). Once the publish was attempted, the
//! previous library is restored from its backup; then what the deployment
//! staged is removed as a best effort, and a removal that fails is owed as a
//! cleanup debt. Both run as ordinary steps of the Job under the use it
//! already consumed: nothing is consumed again, and they are not the debug
//! HAP's declared compensations.
use super::{Journaled, Stop, dispatch_failure, materialized_facts, unbound};
use crate::cleanup_debt::Residue;
use crate::device_facts::{DeviceFacts, HdcComposition};
use crate::device_steps::{self, StepAction};
use crate::job_run::{JobRunner, Run, uncertain};
use crate::operation_catalog::{CatalogOperation, CatalogStep};
use arkdeck_provider_hdc::{Deployment, NativeAbi, NativeAction, validate_elf};
use std::collections::BTreeSet;

impl JobRunner<'_> {
    /// Swift `verifyHostInputArtifact` for `verify-elf-locally` and
    /// `hash-library`: the leased library, resolved again, verified as the
    /// expected ABI's code-signed ELF, and still the digest and size its lease
    /// records. What the lease itself refuses Swift throws past the Job's
    /// lanes.
    pub(super) fn verify_native_library(
        &self,
        run: &mut Run,
        step: &CatalogStep,
    ) -> Result<(), Stop> {
        let inputs = &run.record.request["inputs"];
        let (Some(abi), Some(lease)) = (
            inputs["expectedABI"].as_str().and_then(NativeAbi::parse),
            inputs["libraryArtifactLease"].as_str(),
        ) else {
            return Err(Stop::Failed(
                "native host verification cannot resolve its typed Artifact lease".into(),
            ));
        };
        let leased = self
            .lease(lease)
            .ok()
            .filter(|leased| unbound(leased, &run.record).is_none())
            .ok_or_else(|| Stop::Refused(uncertain()))?;
        let bytes = crate::job_plan::read_library(&leased.path).map_err(|error| {
            Stop::Failed(format!(
                "native host verification cannot read the leased ELF: {error}"
            ))
        })?;
        let facts = validate_elf(&bytes, Some(abi), true).map_err(|error| {
            Stop::Failed(format!(
                "native host verification rejected the leased ELF: {error}"
            ))
        })?;
        if leased.row["sha256"] != facts.sha256.as_str()
            || leased.row["byteCount"].as_i64() != Some(facts.byte_count)
        {
            return Err(Stop::Failed(
                "native Artifact bytes drifted from the leased hash/size".into(),
            ));
        }
        run.record.timeline.push(format!(
            "{} abi={} buildId={} sha256={}",
            step.step_id,
            facts.abi.raw(),
            facts.build_id,
            facts.sha256
        ));
        Ok(())
    }

    /// Swift `compensateNativeLibrary`, after a required step's confirmed
    /// failure, against Target facts that must still name the materialized
    /// binding. Once the publish was attempted (it completed, or the failed
    /// step is it or follows it), `rollback-native-library` restores the
    /// previous library from its backup; a rollback that fails is the Job's
    /// failure. Then `cleanup-native-library-compensation` removes what the
    /// deployment staged; a cleanup that fails is owed as a debt, and unless
    /// its outcome is unknown the Job still fails with its original failure.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn compensate_native_library(
        &self,
        run: &mut Run,
        hdc: &HdcComposition<'_>,
        descriptor: &CatalogOperation,
        deployment: &Deployment,
        completed: &BTreeSet<String>,
        failed_step: &str,
        failure: &str,
        target_id: &str,
        revision: Option<i64>,
    ) -> Result<(), Stop> {
        let facts = hdc
            .facts(target_id)
            .map_err(|_| Stop::Refused(uncertain()))?;
        materialized_facts(&run.record, Some(&facts), target_id, revision)?;
        let index = |id: &str| descriptor.steps.iter().position(|step| step.step_id == id);
        let published = completed.contains("atomic-publish")
            || matches!(
                (index("atomic-publish"), index(failed_step)),
                (Some(publish), Some(failed)) if failed >= publish
            );
        if published {
            let step = device_steps::native_rollback();
            let action = StepAction::Native(Box::new(NativeAction::Rollback(deployment.clone())));
            if let Err(stop) = self.dispatch_compensation(
                run, hdc, descriptor, &step, &action, &facts, target_id, revision,
            ) {
                if let Some(failure) = dispatch_failure(&stop) {
                    run.record
                        .timeline
                        .push(format!("native rollback failed closed: {failure}"));
                }
                return Err(stop);
            }
            run.record
                .timeline
                .push("native deployment failure restored previous library".into());
        }
        let step = device_steps::native_compensation_cleanup();
        let action = StepAction::Native(Box::new(NativeAction::Cleanup(deployment.clone())));
        match self.dispatch_compensation(
            run, hdc, descriptor, &step, &action, &facts, target_id, revision,
        ) {
            Ok(()) => run
                .record
                .timeline
                .push("native compensation cleanup complete".into()),
            Err(stop) => {
                let Some(owed) = dispatch_failure(&stop) else {
                    return Err(stop);
                };
                let residue = Residue::RemotePath(deployment.staging_path.clone());
                self.owe_cleanup(run, &step.step_id, &residue, &owed, &action);
                run.record
                    .timeline
                    .push(format!("native compensation cleanup debt: {owed}"));
                if matches!(stop, Stop::Unknown(_)) {
                    return Err(stop);
                }
            }
        }
        run.record
            .timeline
            .push(format!("native deployment failed: {failure}"));
        Ok(())
    }

    /// One step of the compensation, lowered against the fresh facts and
    /// dispatched as an ordinary step of the Job: journaled, judged and
    /// correlated as every step is, under the use the Job already consumed.
    /// The dispatcher must still prove the executable it retained, as for
    /// every mutation this Runtime dispatches.
    #[allow(clippy::too_many_arguments)]
    fn dispatch_compensation(
        &self,
        run: &mut Run,
        hdc: &HdcComposition<'_>,
        descriptor: &CatalogOperation,
        step: &CatalogStep,
        action: &StepAction,
        facts: &DeviceFacts,
        target_id: &str,
        revision: Option<i64>,
    ) -> Result<(), Stop> {
        let plan = action
            .plan(
                &step.step_id,
                Some(&facts.connect_key),
                &device_steps::NO_CONTEXT,
            )
            .map_err(|_| Stop::Refused(uncertain()))?;
        if !hdc.dispatch.mutation_identity_current() {
            return Err(Stop::Failed(
                "authorizationRequired: fresh tool identity cannot be proved".into(),
            ));
        }
        self.dispatch_step(
            run,
            hdc,
            descriptor,
            step,
            action,
            &plan,
            Some(facts),
            target_id,
            revision,
            &[],
            Journaled::Step,
        )
    }
}
