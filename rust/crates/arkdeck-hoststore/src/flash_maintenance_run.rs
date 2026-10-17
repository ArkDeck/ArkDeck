//! Maintenance runs inside the ordinary Job exclusion, journal and capability owners.
use super::*;
use crate::flash_maintenance::{MaintenanceContext, Prepared, context};
use arkdeck_provider_arkforge::maintenance as m;
use std::sync::Arc;
use std::time::Duration;

fn authority(error: impl std::fmt::Display) -> m::Error {
    m::Error::AuthorityRefused(error.to_string())
}
fn stopped(error: Stop) -> m::Error {
    match error {
        Stop::Refused(_) => m::Error::PersistenceFailed,
        Stop::Failed(s) | Stop::NotExecuted(s) | Stop::Unknown(s) | Stop::Publication(s) => {
            authority(s)
        }
    }
}

fn write_once(path: &std::path::Path, name: &str, value: &Value) -> Result<(), m::Error> {
    let dir =
        arkdeck_platform::HostDirectory::open(path).map_err(|_| m::Error::PersistenceFailed)?;
    let _lock = dir
        .lock_document(".maintenance.lock")
        .map_err(|_| m::Error::PersistenceFailed)?;
    if dir
        .read_owner_only(name, 4 * 1024 * 1024)
        .map_err(|_| m::Error::PersistenceFailed)?
        .is_some()
    {
        return Err(authority(
            "maintenance intent or result already exists; no replay",
        ));
    }
    let bytes =
        crate::session_json::encode_pretty(value).map_err(|_| m::Error::PersistenceFailed)?;
    dir.publish_document(name, &bytes, 4 * 1024 * 1024)
        .map_err(|_| m::Error::PersistenceFailed)
}

fn maintenance_workflow(
    step: &CatalogStep,
    source_plan: &str,
    artifact: &BTreeMap<String, String>,
) -> Result<Value, m::Error> {
    let arguments = if step.step_id == "restore-ramdisk" {
        let mut arguments =
            delegated_arguments("flash-partitions", artifact).ok_or(m::Error::SourceRefused)?;
        arguments["partition"] = json!("ramdisk");
        arguments["providerOperationId"] = json!("arkforge.restore-ramdisk");
        arguments
    } else {
        json!({"probeId":"rockusb-partition-readback",
            "expectedState":format!("sealed-plan:{source_plan}")})
    };
    Ok(
        json!({"id":step.step_id,"kind":step.kind,"effect":step.effect,
        "cancellation":step.cancellation,"bindingRequirement":step.binding,
        "arguments":arguments,"compensationDescriptors":[]}),
    )
}

/// A reservation cannot be reconstructed from caller input. Its capability use,
/// intent and marker are durable before it exists, and survive process restart.
struct Reservation;
struct Port<'a, 'r> {
    owner: &'a FlashRunner<'r>,
    run: &'a mut Run,
    flash: &'a FlashExecution<'a>,
    descriptor: &'a CatalogOperation,
    context: Arc<MaintenanceContext>,
    prepared: Prepared,
    restored: Option<Execution>,
    unknown: bool,
    deadline: Instant,
}
impl Port<'_, '_> {
    fn execution(&self, job: &str) -> Result<&Execution, m::Error> {
        self.restored
            .as_ref()
            .filter(|e| e.daemon_job_id == job)
            .or_else(|| {
                (self.prepared.execution.daemon_job_id == job).then_some(&self.prepared.execution)
            })
            .ok_or(m::Error::SourceRefused)
    }
    fn immutable(&self, name: &str, value: &Value) -> Result<(), m::Error> {
        let path = self
            .owner
            .runner
            .jobs
            .job_directory(&self.run.record.job_id)
            .map_err(|_| m::Error::PersistenceFailed)?;
        write_once(&path, name, value)
    }

    fn intent(&mut self, step_id: &str) -> Result<(), m::Error> {
        let step = self
            .descriptor
            .steps
            .iter()
            .find(|s| s.step_id == step_id)
            .ok_or(m::Error::SourceRefused)?;
        let workflow = maintenance_workflow(
            step,
            &self.prepared.source.plan.plan_sha256,
            &self.prepared.artifact_facts,
        )?;
        self.owner
            .append_intent(
                self.run,
                &format!("intent-{step_id}"),
                &workflow,
                &self.prepared.execution.stable_identity_sha256,
                self.prepared.execution.binding_revision,
            )
            .map_err(stopped)?;
        self.run.record.add_step_kind(&step.kind);
        self.run
            .persist(self.owner.runner.jobs)
            .map_err(|_| m::Error::PersistenceFailed)
    }
    fn outcome(&mut self, step: &str, success: bool) -> Result<(), m::Error> {
        let at = self.run.clock().map_err(|_| m::Error::PersistenceFailed)?;
        self.run
            .step_outcome_at(
                step,
                &format!("intent-{step}"),
                if success { "succeeded" } else { "failed" },
                Some("arkForgeMaintenance"),
                &at,
            )
            .map_err(|_| m::Error::PersistenceFailed)
    }
    fn verify_step(&self) -> &'static str {
        if self.prepared.restoration.is_some() {
            "verify-restored-ramdisk"
        } else {
            "verify-flash-readback"
        }
    }
    fn publish(&mut self, document: Value) -> Result<(), m::Error> {
        self.immutable("maintenance-result.json", &document)?;
        let bytes = crate::session_json::encode_pretty(&document)
            .map_err(|_| m::Error::PersistenceFailed)?;
        self.owner
            .publish_step_product(
                self.run,
                self.descriptor,
                self.verify_step(),
                "maintenance-result.json",
                &bytes,
                None,
            )
            .map_err(authority)?;
        self.run.record.set_maintenance_result(document);
        self.run
            .persist(self.owner.runner.jobs)
            .map_err(|_| m::Error::PersistenceFailed)
    }
}
impl m::VerificationPort for Port<'_, '_> {
    fn load_source(&mut self, job: &str) -> Result<m::Source, m::Error> {
        let execution = self.execution(job)?;
        let records = self
            .context
            .lane
            .maintenance_source(execution)
            .map_err(authority)?;
        Ok(m::Source {
            authority_namespace: "arkdeck".into(),
            profile: execution.artifact_profile_id.clone(),
            campaign: records.plan.authority_support_campaign.clone(),
            latest_job: records.job.job_id.clone(),
            job: records.job,
            plan: records.plan,
            receipts: records.receipts,
            identity: self.prepared.source.identity.clone(),
            active_jobs: records.active_jobs,
        })
    }
    fn fresh_identity(
        &mut self,
        source: &m::Source,
        deadline: Instant,
    ) -> Result<m::Identity, m::Error> {
        self.context
            .reads
            .observe(
                self.execution(&source.job.job_id)?,
                deadline.min(self.deadline),
            )
            .map(|(identity, _)| identity)
            .map_err(authority)
    }
    fn verification_intent(&mut self, source: &m::Source, budget_ms: u64) -> Result<(), m::Error> {
        self.immutable("maintenance-verification-intent.json", &json!({
            "schema":"arkdeck.maintenance-intent/v1","jobId":self.run.record.job_id,
            "sourceJobId":source.job.job_id,"sealedPlan":source.plan.encode(),"budgetMs":budget_ms,
            "serialSHA256":source.identity.serial_sha256,"topologySHA256":source.identity.topology_sha256,
            "descriptorSHA256":source.identity.descriptor_sha256,
            "toolSHA256":self.prepared.execution.toolchain_sha256,
        }))?;
        self.intent(self.verify_step())
    }
    fn read_partition(
        &mut self,
        source: &m::Source,
        effect: &m::Effect,
        deadline: Instant,
    ) -> Result<m::ReadOutcome, m::Error> {
        self.context
            .reads
            .read(
                self.execution(&source.job.job_id)?,
                effect,
                deadline.min(self.deadline),
            )
            .map_err(authority)
    }
    fn verification_result(&mut self, result: &m::VerificationResult) -> Result<(), m::Error> {
        let document = m::verification_document(result);
        self.immutable("maintenance-verification.json", &document)?;
        self.outcome(self.verify_step(), result.exit_code() != 7)?;
        if self.prepared.restoration.is_none() {
            self.publish(document)?;
        }
        Ok(())
    }
}
impl m::RestorationPort for Port<'_, '_> {
    type Reservation = Reservation;
    fn restoration_plan(
        &mut self,
        _source: &m::Source,
        artifact: &str,
        deadline: Instant,
    ) -> Result<m::ExecutablePlan, m::Error> {
        if Instant::now() >= deadline
            || self
                .prepared
                .artifact
                .as_ref()
                .is_none_or(|a| a.sha256 != artifact)
        {
            return Err(m::Error::SourceRefused);
        }
        self.prepared
            .restoration
            .clone()
            .ok_or(m::Error::SourceRefused)
    }
    fn reserve_restoration(
        &mut self,
        source: &m::Source,
        plan: &m::ExecutablePlan,
        deadline: Instant,
    ) -> Result<Reservation, m::Error> {
        if Instant::now() >= deadline || self.prepared.restoration.as_ref() != Some(plan) {
            return Err(m::Error::SourceRefused);
        }
        let facts = (self.flash.facts)(&self.prepared.execution.target_id).map_err(authority)?;
        let resolved = self.owner.resolved_input(self.run).map_err(authority)?;
        self.owner
            .consume(
                self.run,
                self.flash,
                self.descriptor,
                Some(&facts),
                &resolved,
            )
            .map_err(stopped)?;
        self.immutable(
            "maintenance-reservation.json",
            &json!({
                "schema":"arkdeck.maintenance-reservation/v1","sourceJobId":source.job.job_id,
                "jobId":self.run.record.job_id,"plan":plan.encode(),
                "admissionEvidence":self.run.record.admission_evidence(),
            }),
        )?;
        self.intent("restore-ramdisk")?;
        Ok(Reservation)
    }
    fn execute_restoration(
        &mut self,
        _reservation: Reservation,
        deadline: Instant,
    ) -> Result<String, m::Error> {
        if Instant::now() >= deadline {
            return Err(m::Error::BudgetExhausted);
        }
        let artifact = self
            .prepared
            .artifact
            .as_ref()
            .ok_or(m::Error::SourceRefused)?;
        let plan = self
            .prepared
            .restoration
            .as_ref()
            .ok_or(m::Error::SourceRefused)?;
        // From this boundary an error is unknown unless the lane proves non-execution.
        self.unknown = true;
        let execution = self
            .context
            .lane
            .prepare_restoration(
                &self.run.record.job_id,
                plan,
                artifact,
                &self.prepared.binding,
            )
            .map_err(|e| authority(format!("{e:?}")))?;
        let mut state = ArkForgeJobState {
            execution: Some(execution.clone()),
            completion: None,
        };
        self.owner
            .runner
            .jobs
            .persist_arkforge_state(&self.run.record.job_id, &state)
            .map_err(|_| m::Error::PersistenceFailed)?;
        if Instant::now() >= deadline {
            return Err(m::Error::BudgetExhausted);
        }
        let receipt = self
            .context
            .lane
            .perform_restoration(&execution, artifact, &self.prepared.binding, deadline)
            .map_err(|e| authority(format!("{e:?}")))?;
        if !validate_completion(&receipt, Some(&execution)) {
            return Err(m::Error::SourceRefused);
        }
        state.completion = Some(receipt);
        self.owner
            .runner
            .jobs
            .persist_arkforge_state(&self.run.record.job_id, &state)
            .map_err(|_| m::Error::PersistenceFailed)?;
        self.outcome("restore-ramdisk", true)?;
        self.unknown = false;
        let job = execution.daemon_job_id.clone();
        self.restored = Some(execution);
        Ok(job)
    }
    fn restoration_result(
        &mut self,
        source_job: &str,
        result: &m::RestorationResult,
    ) -> Result<(), m::Error> {
        let mut document = m::restoration_document(result);
        document["source_job_id"] = json!(source_job);
        document["outcome_unknown"] = json!(self.unknown);
        self.publish(document)
    }
}

impl FlashRunner<'_> {
    fn stop_maintenance_before_dispatch(
        &self,
        run: &mut Run,
        request: &OperationRequest,
        reason: &str,
    ) -> Result<Option<String>, RunRefusal> {
        if request.operation_id == "flash.restore-boot-loop" {
            let document = json!({"schema":"arkforge.boot-loop-restoration/v1",
                "source_job_id":request.inputs["sourceJobId"], "exit_code":1,
                "outcome":"stopped", "outcome_unknown":false, "reason":reason});
            let directory = self
                .runner
                .jobs
                .job_directory(&run.record.job_id)
                .map_err(|_| uncertain())?;
            write_once(&directory, "maintenance-result.json", &document)
                .map_err(|_| uncertain())?;
            run.record.set_maintenance_result(document);
        }
        let started = run.clock()?;
        run.record.start(&started);
        run.transition("preflight", "running", "maintenance preflight stopped")?;
        run.record.set_operation_failure(Some(failure(
            "maintenanceStopped",
            "execution",
            "notAutomatic",
            "inspectJob",
        )));
        run.transition("running", "finalizing", reason)?;
        run.transition("finalizing", "failed", reason)?;
        run.finish()?;
        run.persist(self.runner.jobs)?;
        self.runner.settle_mutation(run, UseOutcome::Confirmed)?;
        Ok(None)
    }

    pub(super) fn run_maintenance(
        &self,
        run: &mut Run,
        flash: &FlashExecution<'_>,
        descriptor: &CatalogOperation,
    ) -> Result<Option<String>, RunRefusal> {
        let request = OperationRequest::decode(
            &serde_json::to_vec(&run.record.request).map_err(|_| uncertain())?,
        )
        .map_err(|_| uncertain())?;
        let budget = request
            .inputs
            .get("budgetMs")
            .and_then(Value::as_u64)
            .filter(|n| (1_000..=600_000).contains(n))
            .ok_or_else(uncertain)?;
        let deadline = Instant::now() + Duration::from_millis(budget);
        let target = request.target_id.clone();
        let holder = run.record.job_id.clone();
        let abandon = || Instant::now() >= deadline;
        let _lane = flash
            .targets
            .enter_mutation_lane(&target, &holder, Some(&abandon))
            .map_err(|_| uncertain())?
            .ok_or_else(uncertain)?;
        let context = context(flash.planning).map_err(|e| proven("rejected", e, Some(&holder)))?;
        let state_root = self.runner.mutation.ok_or_else(uncertain)?.state_root;
        let planner = JobPlanner {
            artifacts: Some(self.runner.artifacts),
            imports: self.runner.imports,
            analyzer: None,
            state_root,
            hdc: None,
            workspace: None,
        };
        let prepared = match context.prepare(&request, &planner) {
            Ok(prepared) => prepared,
            Err(reason) => return self.stop_maintenance_before_dispatch(run, &request, &reason),
        };
        if Some(prepared.digest.as_str()) != run.record.materialized_plan()
            || Instant::now() >= deadline
        {
            return self.stop_maintenance_before_dispatch(
                run,
                &request,
                "maintenance plan or budget changed",
            );
        }
        let started = run.clock()?;
        run.record.start(&started);
        run.transition("preflight", "running", "maintenance-start")?;
        run.persist(self.runner.jobs)?;
        let source = prepared.source.job.job_id.clone();
        let artifact = prepared.artifact.as_ref().map(|a| a.sha256.clone());
        let mut port = Port {
            owner: self,
            run,
            flash,
            descriptor,
            context,
            prepared,
            restored: None,
            unknown: false,
            deadline,
        };
        let remaining = deadline
            .saturating_duration_since(Instant::now())
            .as_millis() as u64;
        let result = if let Some(artifact) = artifact {
            m::restore(&mut port, &source, &artifact, remaining).map(|r| r.exit_code())
        } else {
            m::verify(&mut port, &source, remaining).map(|r| r.exit_code())
        };
        let unknown = port.unknown;
        drop(port);
        if !unknown {
            // Close only this run's intents for which no provider effect is uncertain.
            let outstanding = run.journal.facts().outstanding_intents;
            for intent in outstanding {
                let at = run.clock()?;
                run.step_outcome_at(
                    &intent.step_id,
                    &intent.event_id,
                    "failed",
                    Some(if intent.effect == "destructive" {
                        "confirmedNotExecuted"
                    } else {
                        "maintenanceStopped"
                    }),
                    &at,
                )?;
            }
        }
        if unknown {
            run.record.set_outcome_unknown();
            run.record.set_operation_failure(Some(failure(
                "outcomeUnknown",
                "unknownOutcome",
                "runtimeDecisionRequired",
                "awaitRuntimeReconciliation",
            )));
            run.transition(
                "running",
                "waitingForRecovery",
                "maintenance stopped with unknown outcome; no replay",
            )?;
        } else {
            let success = matches!(result, Ok(0 | 9));
            if !success {
                run.record.set_operation_failure(Some(failure(
                    "maintenanceStopped",
                    "execution",
                    "notAutomatic",
                    "inspectJob",
                )));
            }
            let reason = result
                .map(|code| format!("maintenance exit {code}"))
                .unwrap_or_else(|e| format!("maintenance stopped: {e}"));
            run.transition("running", "finalizing", &reason)?;
            run.transition(
                "finalizing",
                if success { "succeeded" } else { "failed" },
                &reason,
            )?;
        }
        run.finish()?;
        run.persist(self.runner.jobs)?;
        self.runner.settle_mutation(
            run,
            if unknown {
                UseOutcome::OutcomeUnknown
            } else {
                UseOutcome::Confirmed
            },
        )?;
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    #[test]
    fn maintenance_catalog_intents_append_and_replay_in_real_journal() {
        use crate::job_journal_events::{self as events, Envelope, Target};
        use crate::job_journal_writer::JournalWriter;
        for operation in ["flash.verify@1", "flash.restore-boot-loop@1"] {
            let root = std::env::temp_dir().join(format!(
                "arkdeck-maintenance-journal-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            #[cfg(windows)]
            arkdeck_platform::create_private_directory(&root).unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                std::fs::DirBuilder::new()
                    .mode(0o700)
                    .create(&root)
                    .unwrap();
            }
            let root = root.canonicalize().unwrap();
            let at = |sequence| Envelope {
                event_id: format!("evt-{sequence}"),
                sequence,
                session_id: "session-maintenance".into(),
                job_id: "job-maintenance".into(),
                timestamp: format!("2026-09-13T00:00:{sequence:02}Z"),
            };
            let target = Target {
                scope: "device".into(),
                target_id: "TGT-fixture".into(),
                connect_key: Some("fixture-only".into()),
                identity_snapshot_hash: Some("b".repeat(64)),
            };
            let artifact = BTreeMap::from([
                ("artifactId".into(), "original-image".into()),
                ("artifactSha256".into(), "a".repeat(64)),
                ("artifactByteCount".into(), "4096".into()),
            ]);
            let mut writer = JournalWriter::open(&root, true).unwrap();
            writer
                .append(&events::job_created(
                    &at(0),
                    "execute",
                    "standardAgent",
                    "CORE-3.0.0",
                ))
                .unwrap();
            writer
                .append(&events::state_transition(
                    &at(1),
                    "queued",
                    "preflight",
                    "admitted",
                    None,
                ))
                .unwrap();
            let steps = &descriptor_of(operation).unwrap().steps;
            for (index, step) in steps.iter().enumerate() {
                let workflow = maintenance_workflow(step, &"c".repeat(64), &artifact).unwrap();
                writer
                    .append(
                        &events::step_intent(&at(index as i64 + 2), &workflow, &target, 1, Some(1))
                            .unwrap(),
                    )
                    .unwrap();
            }
            drop(writer);
            let reopened = JournalWriter::open(&root, false).unwrap();
            assert_eq!(reopened.facts().outstanding_intents.len(), steps.len());
            drop(reopened);
            std::fs::remove_dir_all(root).unwrap();
        }
    }
    #[test]
    fn maintenance_intent_survives_reopen_and_refuses_replay() {
        let root = std::env::temp_dir().join(format!(
            "arkdeck-maintenance-once-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        #[cfg(windows)]
        arkdeck_platform::create_private_directory(&root).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&root)
                .unwrap();
        }
        let root = root.canonicalize().unwrap();
        let intent = json!({"source":"source-1","plan":"sealed-plan-1"});
        write_once(&root, "maintenance-intent.json", &intent).unwrap();
        let bytes = std::fs::read(root.join("maintenance-intent.json")).unwrap();
        assert!(write_once(&root, "maintenance-intent.json", &intent).is_err());
        assert!(write_once(&root, "maintenance-intent.json", &json!({"plan":"other"})).is_err());
        assert_eq!(
            std::fs::read(root.join("maintenance-intent.json")).unwrap(),
            bytes
        );
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn maintenance_unwritable_intent_is_a_persistence_failure() {
        let missing = std::env::temp_dir().join(format!(
            "arkdeck-maintenance-missing-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        assert!(matches!(
            write_once(&missing, "intent.json", &json!({})),
            Err(m::Error::PersistenceFailed)
        ));
        assert!(!missing.exists());
    }
}
