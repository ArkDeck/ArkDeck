//! Candidate policy tests over real Runtime owners and synthetic Provider ports.
//! No installed Runtime, HDC, device, or hardware evidence is involved.
use super::*;
use arkdeck_hoststore::{MaintenanceContext, MaintenanceObservation, MaintenanceReads};
use arkdeck_provider_arkforge::{
    ActionReceipt, DeviceBinding, Execution, FlashLane, LaneArtifact, LaneFailure, PrewarmReceipt,
    Terminal, maintenance as m,
};
use std::sync::atomic::{AtomicUsize, Ordering};

const CAMPAIGN: &str = "synthetic-maintenance-policy";
const RESTORATION_PLAN: &str = "PLAN-MAINTENANCE-RESTORATION";

#[derive(Default)]
struct Calls {
    prepares: AtomicUsize,
    writes: AtomicUsize,
    reads: AtomicUsize,
    bad_readback: AtomicUsize,
    bad_evidence: AtomicUsize,
    mounted_writable: AtomicUsize,
}

struct Lane {
    inner: Arc<FakeLane>,
    calls: Arc<Calls>,
}

fn restoration_plan() -> m::ExecutablePlan {
    let mut plan = m::ExecutablePlan {
        plan_id: RESTORATION_PLAN.into(),
        plan_sha256: "9".repeat(64),
        execution_purpose: "primaryFlash".into(),
        authority_support_campaign: CAMPAIGN.into(),
        mechanics_maturity_campaign: CAMPAIGN.into(),
        expires_at_epoch_ms: u64::MAX,
        persistent_effects: vec![m::Effect {
            kind: "writePartition".into(),
            target: "ramdisk".into(),
            range_start: m::RAMDISK_START,
            range_length: m::RAMDISK_BYTES,
            content_sha256: m::RESTORATION_SHA256.into(),
        }],
        ..Default::default()
    };
    for (index, kind) in [
        "probeDevice",
        "validateLayout",
        "writeTarget",
        "verifyTarget",
        "reboot",
        "postflightProbe",
    ]
    .into_iter()
    .enumerate()
    {
        let partition = matches!(kind, "writeTarget" | "verifyTarget");
        plan.public_steps.push(m::PublicStep {
            step_id: format!("MAINTENANCE-STEP-{index}"),
            kind: kind.into(),
            semantic_target: if partition {
                "partition:ramdisk"
            } else {
                "device"
            }
            .into(),
            content_sha256: if partition {
                m::RESTORATION_SHA256.into()
            } else {
                String::new()
            },
            ..Default::default()
        });
    }
    plan
}

impl FlashLane for Lane {
    fn toolchain_sha256(&self) -> &str {
        self.inner.toolchain_sha256()
    }
    fn prewarm(&self, job: &str, artifact: &LaneArtifact) -> Result<PrewarmReceipt, LaneFailure> {
        self.inner.prewarm(job, artifact)
    }
    fn finish_prewarm(&self, job: &str) {
        self.inner.finish_prewarm(job);
    }
    fn prepare(
        &self,
        job: &str,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
        purpose: &str,
    ) -> Result<Execution, LaneFailure> {
        self.inner.prepare(job, artifact, binding, purpose)
    }
    fn perform(
        &self,
        step: &str,
        execution: &Execution,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
    ) -> Result<ActionReceipt, LaneFailure> {
        self.inner.perform(step, execution, artifact, binding)
    }
    fn observe_terminal(&self, execution: &Execution) -> Result<Option<Terminal>, String> {
        self.inner.observe_terminal(execution)
    }
    fn completed_plan_receipt(&self, job: &str) -> Option<ActionReceipt> {
        self.inner.completed_plan_receipt(job)
    }
    fn maintenance_source(&self, execution: &Execution) -> Result<m::SourceRecords, String> {
        let mut source = self.inner.maintenance_source(execution)?;
        source.plan.authority_support_campaign = CAMPAIGN.into();
        source.plan.mechanics_maturity_campaign = CAMPAIGN.into();
        if execution.plan_id == RESTORATION_PLAN {
            source.plan = restoration_plan();
            source.receipts = source
                .plan
                .public_steps
                .iter()
                .map(|step| m::ActionReceiptSummary {
                    job_id: execution.daemon_job_id.clone(),
                    plan_id: execution.plan_id.clone(),
                    step_id: step.step_id.clone(),
                    attempt_id: "MAINTENANCE-ATTEMPT-1".into(),
                    permit_id: "MAINTENANCE-PERMIT-1".into(),
                    disposition: "semanticSuccess".into(),
                    evidence_sha256: vec![0xab; 32],
                    ..Default::default()
                })
                .collect();
            source.job.total_steps = source.plan.public_steps.len() as u64;
            source.job.completed_steps = source.job.total_steps;
        }
        Ok(source)
    }
    fn restoration_plan(
        &self,
        _artifact: &LaneArtifact,
        _binding: &DeviceBinding,
    ) -> Result<m::ExecutablePlan, String> {
        Ok(restoration_plan())
    }
    fn prepare_restoration(
        &self,
        job: &str,
        plan: &m::ExecutablePlan,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
    ) -> Result<Execution, LaneFailure> {
        self.calls.prepares.fetch_add(1, Ordering::SeqCst);
        self.inner.prepare_restoration(job, plan, artifact, binding)
    }
    fn perform_restoration(
        &self,
        execution: &Execution,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
        deadline: Instant,
    ) -> Result<ActionReceipt, LaneFailure> {
        self.calls.writes.fetch_add(1, Ordering::SeqCst);
        self.inner
            .perform_restoration(execution, artifact, binding, deadline)
    }
}

struct Reads {
    fakes: Fakes,
    calls: Arc<Calls>,
}
impl MaintenanceReads for Reads {
    fn observe_evidence(
        &self,
        execution: &Execution,
        deadline: Instant,
    ) -> Result<MaintenanceObservation, String> {
        if self.calls.bad_evidence.load(Ordering::SeqCst) == 1 {
            return Err("synthetic evidence read unavailable".into());
        }
        let (identity, mut binding) = self.observe(execution, deadline)?;
        if self.calls.bad_evidence.load(Ordering::SeqCst) == 2 {
            binding.binding_revision += 1;
        }
        Ok(MaintenanceObservation {
            identity,
            binding,
            model: "synthetic-board".into(),
            firmware: "synthetic-firmware".into(),
        })
    }
    fn observe(
        &self,
        execution: &Execution,
        deadline: Instant,
    ) -> Result<(m::Identity, DeviceBinding), String> {
        let facts = self.fakes.facts(&execution.target_id)?;
        if Instant::now() >= deadline
            || facts.binding_revision != execution.binding_revision
            || facts.identity_sha256 != execution.stable_identity_sha256
        {
            return Err("synthetic fresh source binding differs".into());
        }
        Ok((
            m::Identity {
                serial_sha256: execution.stable_identity_sha256.clone(),
                topology_sha256: arkdeck_contract::sha256_hex(execution.usb_topology.as_bytes()),
                descriptor_sha256: "d".repeat(64),
            },
            DeviceBinding {
                target_id: execution.target_id.clone(),
                binding_revision: execution.binding_revision,
                stable_identity_sha256: execution.stable_identity_sha256.clone(),
                connect_key: facts.execution_connect_key,
                usb_topology: execution.usb_topology.clone(),
                loader_first_connector_sha256: None,
                recommission: None,
            },
        ))
    }
    fn read(
        &self,
        execution: &Execution,
        effect: &m::Effect,
        deadline: Instant,
    ) -> Result<m::ReadOutcome, String> {
        self.observe(execution, deadline)?;
        self.calls.reads.fetch_add(1, Ordering::SeqCst);
        if self.calls.mounted_writable.load(Ordering::SeqCst) != 0 {
            return Ok(m::ReadOutcome::MountedWritable);
        }
        Ok(m::ReadOutcome::FullHash(
            if self.calls.bad_readback.load(Ordering::SeqCst) != 0 {
                "0".repeat(64)
            } else {
                effect.content_sha256.clone()
            },
        ))
    }
}

fn install(owners: &Owners, fakes: &Fakes, calls: &Arc<Calls>) {
    owners
        .flash
        .install_maintenance(Arc::new(MaintenanceContext::new(
            owners.jobs.clone(),
            Arc::new(Lane {
                inner: owners.lane.clone(),
                calls: calls.clone(),
            }),
            Arc::new(Reads {
                fakes: fakes.clone(),
                calls: calls.clone(),
            }),
        )));
}

fn request(source: &str, id: &str, restoring: bool) -> Value {
    let mut request: Value = serde_json::from_str(
        recorded("failures", "prewarmRefused.submit")["params"]["requestJson"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    let lease = request["inputs"]["artifactLease"].clone();
    request["requestId"] = json!(format!("req-maintenance-{id}"));
    request["idempotencyKey"] = json!(format!("idem-maintenance-{id}"));
    request["operation"] =
        json!({"id":if restoring {"flash.restore-boot-loop"} else {"flash.verify"},"version":1});
    request["inputs"] = json!({"sourceJobId":source,"budgetMs":600000});
    if restoring {
        request["inputs"]["artifactLease"] = lease;
    }
    json!({"requestJson":request.to_string()})
}

fn primary(owners: &Owners, fakes: &Fakes) -> String {
    fakes.begin(Script::default());
    let params = recorded("failures", "prewarmRefused.submit")["params"].clone();
    let accepted = owners.answer(fakes, "job.submit", params.as_object().unwrap());
    let job = accepted["result"]["jobId"]
        .as_str()
        .unwrap_or_else(|| panic!("{accepted}"))
        .to_owned();
    let run = owners.answer(fakes, "job.run", json!({"jobId":job}).as_object().unwrap());
    assert_eq!(run["result"]["state"], "succeeded", "{run}");
    job
}

fn submit(owners: &Owners, fakes: &Fakes, params: &Value) -> String {
    let plan = owners.answer(fakes, "job.plan", params.as_object().unwrap());
    assert_eq!(plan["ok"], true, "{plan}");
    assert_eq!(plan["result"]["jobAdmitted"], false);
    let mut raw: Value = serde_json::from_str(params["requestJson"].as_str().unwrap()).unwrap();
    raw["reviewedPlanDigest"] = plan["result"]["materializedPlanDigest"].clone();
    let submitted = owners.answer(
        fakes,
        "job.submit",
        json!({"requestJson":raw.to_string()}).as_object().unwrap(),
    );
    submitted["result"]["jobId"]
        .as_str()
        .unwrap_or_else(|| panic!("{submitted}"))
        .to_owned()
}

fn run(owners: &Owners, fakes: &Fakes, job: &str) -> Value {
    run_with_clock(owners, fakes, job, now)
}

fn run_with_clock(
    owners: &Owners,
    fakes: &Fakes,
    job: &str,
    clock: fn() -> Option<String>,
) -> Value {
    let answer = owners.answer_with_clock(
        fakes,
        "job.run",
        json!({"jobId":job}).as_object().unwrap(),
        clock,
        precise_now,
    );
    if answer["ok"] == true
        && let Err(error) =
            arkdeck_contract::validate_method_value("job.status", "result", &answer["result"])
    {
        panic!("produced status violates its contract: {error:?}; {answer}");
    }
    answer
}

fn uses(root: &Path) -> usize {
    let directory = root.join("store/capabilities");
    let folded = fs::read(directory.join("runtime-capabilities.json")).map_or(0, |bytes| {
        let checkpoint: Value = serde_json::from_slice(&bytes).unwrap();
        checkpoint["records"]
            .as_array()
            .unwrap()
            .iter()
            .map(|record| record["consumptions"].as_array().unwrap().len())
            .sum()
    });
    let appended = fs::read_to_string(directory.join("runtime-capabilities.ledger"))
        .unwrap_or_default()
        .lines()
        .filter(|line| serde_json::from_str::<Value>(line).unwrap()["kind"] == "consumed")
        .count();
    folded + appended
}

fn source_history(owners: &Owners, source: &str) -> Vec<Vec<u8>> {
    [
        "job-record.json",
        "journal.jsonl",
        "arkforge-runtime-state.json",
    ]
    .iter()
    .map(|name| fs::read(owners.state_root().join("jobs").join(source).join(name)).unwrap())
    .collect()
}

fn assert_published_result(owners: &Owners, fakes: &Fakes, job: &str) {
    let params = json!({"jobId":job});
    for method in ["job.result", "job.evidence"] {
        let answer = owners.answer(fakes, method, params.as_object().unwrap());
        assert_eq!(answer["ok"], true, "{method}: {answer}");
        arkdeck_contract::validate_method_value(method, "result", &answer["result"])
            .unwrap_or_else(|error| panic!("{method}: {error:?}; {answer}"));
        let evidence = if method == "job.result" {
            assert_eq!(
                answer["result"]["job"]["sessionPublication"]["state"], "published",
                "{answer}"
            );
            assert_eq!(answer["result"]["artifacts"].as_array().unwrap().len(), 1);
            &answer["result"]["evidence"]
        } else {
            &answer["result"]
        };
        assert_eq!(evidence["status"], "verified", "{answer}");
        assert_eq!(
            evidence["observation"]["confirmationMethod"], "machineReadback",
            "{answer}"
        );
        assert_eq!(evidence["outcomeUnknown"], false);
        assert_eq!(evidence["missingRequiredArtifacts"], json!([]));
        assert_eq!(evidence["artifacts"][0]["bytesVerified"], true);
        if evidence["authority"]["kind"] == "runtimeCapability" {
            assert!(
                evidence["observation"]["confirmedAtUtc"].as_str().unwrap()
                    < evidence["authority"]["admittedAtUtc"].as_str().unwrap(),
                "{answer}"
            );
        }
    }
}

#[test]
fn restoration_policy_uses_one_exact_ramdisk_capability_and_independent_readback() {
    static TICKS: AtomicUsize = AtomicUsize::new(0);
    fn advancing_clock() -> Option<String> {
        let tick = TICKS.fetch_add(1, Ordering::SeqCst);
        Some(format!("2026-09-25T00:{:02}:{:02}Z", tick / 60, tick % 60))
    }
    let _lock = exclusive();
    TICKS.store(0, Ordering::SeqCst);
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = primary(&owners, &fakes);
    let original = source_history(&owners, &source);
    let original_uses = uses(&root);
    let calls = Arc::new(Calls::default());
    install(&owners, &fakes, &calls);
    let job = submit(&owners, &fakes, &request(&source, "success", true));
    let result = run_with_clock(&owners, &fakes, &job, advancing_clock);
    assert_eq!(result["result"]["state"], "succeeded", "{result}");
    assert_eq!(
        result["result"]["maintenanceResult"]["exit_code"], 0,
        "{result}"
    );
    assert_published_result(&owners, &fakes, &job);
    assert_eq!(calls.prepares.load(Ordering::SeqCst), 1);
    assert_eq!(calls.writes.load(Ordering::SeqCst), 1);
    assert_eq!(calls.reads.load(Ordering::SeqCst), 1);
    assert_eq!(uses(&root), original_uses + 1);
    let reserved: Value = serde_json::from_slice(
        &fs::read(
            root.join("store/jobs")
                .join(&job)
                .join("maintenance-reservation.json"),
        )
        .unwrap(),
    )
    .unwrap();
    let encoded: Vec<u8> = serde_json::from_value(reserved["plan"].clone()).unwrap();
    let plan = m::ExecutablePlan::decode(&encoded).unwrap();
    assert_eq!(
        plan.persistent_effects,
        restoration_plan().persistent_effects
    );
    assert_eq!(reserved["admissionEvidence"]["kind"], "runtimeCapability");
    let stored: Value = serde_json::from_slice(
        &fs::read(root.join("store/jobs").join(&job).join("job-record.json")).unwrap(),
    )
    .unwrap();
    let duplicate = owners.answer(
        &fakes,
        "job.submit",
        json!({
            "requestJson":stored["originalSubmissionRequest"].to_string(),
        })
        .as_object()
        .unwrap(),
    );
    assert_eq!(duplicate["result"]["jobId"], job, "{duplicate}");
    let again = run(&owners, &fakes, &job);
    assert_eq!(again["error"]["code"], "resourceConflict", "{again}");
    assert_eq!(calls.writes.load(Ordering::SeqCst), 1);
    let verify = submit(&owners, &fakes, &request(&job, "verify-restored", false));
    let verified = run_with_clock(&owners, &fakes, &verify, advancing_clock);
    assert_eq!(verified["result"]["state"], "succeeded", "{verified}");
    assert_eq!(
        verified["result"]["maintenanceResult"]["exit_code"], 0,
        "{verified}"
    );
    assert_published_result(&owners, &fakes, &verify);
    assert_eq!(calls.writes.load(Ordering::SeqCst), 1);
    assert_eq!(calls.reads.load(Ordering::SeqCst), 2);
    assert_eq!(uses(&root), original_uses + 1);
    assert_eq!(source_history(&owners, &source), original);
}

#[test]
fn maintenance_missing_or_mismatched_evidence_stops_before_any_write() {
    let _lock = exclusive();
    for restoring in [false, true] {
        for bad_evidence in [1, 2] {
            let root = lay_down();
            let fakes = Fakes::default();
            let owners = Owners::open(&root, &fakes);
            let source = primary(&owners, &fakes);
            let original = source_history(&owners, &source);
            let original_uses = uses(&root);
            let calls = Arc::new(Calls::default());
            install(&owners, &fakes, &calls);
            let job = submit(
                &owners,
                &fakes,
                &request(&source, "evidence-refused", restoring),
            );
            calls.bad_evidence.store(bad_evidence, Ordering::SeqCst);
            let stopped = run(&owners, &fakes, &job);
            assert_eq!(stopped["result"]["state"], "failed", "{stopped}");
            assert_eq!(stopped["result"]["outcomeUnknown"], false);
            assert_eq!(calls.prepares.load(Ordering::SeqCst), 0);
            assert_eq!(calls.writes.load(Ordering::SeqCst), 0);
            assert_eq!(calls.reads.load(Ordering::SeqCst), 0);
            assert_eq!(uses(&root), original_uses);
            assert_eq!(source_history(&owners, &source), original);
        }
    }
}

#[test]
fn maintenance_partial_verification_remains_readable_and_published() {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = primary(&owners, &fakes);
    let calls = Arc::new(Calls::default());
    install(&owners, &fakes, &calls);
    let job = submit(&owners, &fakes, &request(&source, "partial", false));
    calls.mounted_writable.store(1, Ordering::SeqCst);
    let result = run(&owners, &fakes, &job);
    assert_eq!(result["result"]["state"], "succeeded", "{result}");
    let report = &result["result"]["maintenanceResult"];
    assert_eq!(report["exit_code"], 9, "{report}");
    assert_eq!(report["outcome"], "partial");
    assert_eq!(report["verified"], 0);
    assert_eq!(report["failed"], 0);
    assert!(report["skipped"].as_u64().unwrap() > 0);
    assert_published_result(&owners, &fakes, &job);
    assert_eq!(calls.writes.load(Ordering::SeqCst), 0);
}

#[test]
fn restoration_policy_refuses_supplied_authority_without_new_job_or_dispatch() {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = primary(&owners, &fakes);
    let original = source_history(&owners, &source);
    let original_uses = uses(&root);
    let jobs_before = fs::read_dir(root.join("store/jobs")).unwrap().count();
    let source_record = owners.jobs.read_snapshot(&source).unwrap();
    let calls = Arc::new(Calls::default());
    install(&owners, &fakes, &calls);
    for (label, capability) in [
        (
            "existing",
            source_record.request["authorization"]["capabilityId"].clone(),
        ),
        ("unknown", json!("CAP-RT-UNKNOWN")),
    ] {
        let params = request(&source, label, true);
        let mut raw: Value = serde_json::from_str(params["requestJson"].as_str().unwrap()).unwrap();
        raw["authorization"] = json!({"capabilityId":capability});
        let answer = owners.answer(
            &fakes,
            "job.submit",
            json!({
                "requestJson":raw.to_string(),
            })
            .as_object()
            .unwrap(),
        );
        assert_eq!(answer["error"]["code"], "rejected", "{answer}");
        assert_eq!(answer["error"]["details"]["phase"], "preAdmission");
        assert_eq!(answer["error"]["details"]["newDispatchCount"], 0);
        assert!(
            answer["error"]["message"]
                .as_str()
                .unwrap()
                .contains("caller-supplied capabilities cannot admit a Runtime-owned policy"),
            "{answer}"
        );
    }
    assert_eq!(
        fs::read_dir(root.join("store/jobs")).unwrap().count(),
        jobs_before
    );
    assert_eq!(uses(&root), original_uses);
    assert_eq!(calls.prepares.load(Ordering::SeqCst), 0);
    assert_eq!(calls.writes.load(Ordering::SeqCst), 0);
    assert_eq!(calls.reads.load(Ordering::SeqCst), 0);
    assert_eq!(source_history(&owners, &source), original);
}

#[test]
fn restoration_policy_binding_drift_stops_before_consumption_and_dispatch() {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = primary(&owners, &fakes);
    let calls = Arc::new(Calls::default());
    install(&owners, &fakes, &calls);
    let job = submit(&owners, &fakes, &request(&source, "binding-drift", true));
    let ledger = fs::read(root.join("store/capabilities/runtime-capabilities.ledger")).unwrap();
    fakes.begin(Script {
        binding_revision: 2,
        ..Default::default()
    });
    let stopped = run(&owners, &fakes, &job);
    assert_eq!(stopped["result"]["state"], "failed", "{stopped}");
    assert_eq!(calls.prepares.load(Ordering::SeqCst), 0);
    assert_eq!(calls.writes.load(Ordering::SeqCst), 0);
    assert_eq!(
        fs::read(root.join("store/capabilities/runtime-capabilities.ledger")).unwrap(),
        ledger
    );
}

#[test]
fn restoration_policy_failed_full_readback_never_reports_success() {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = primary(&owners, &fakes);
    let calls = Arc::new(Calls::default());
    install(&owners, &fakes, &calls);
    let job = submit(&owners, &fakes, &request(&source, "bad-readback", true));
    calls.bad_readback.store(1, Ordering::SeqCst);
    let stopped = run(&owners, &fakes, &job);
    assert_eq!(stopped["result"]["state"], "failed", "{stopped}");
    assert_eq!(
        stopped["result"]["maintenanceResult"]["exit_code"], 1,
        "{stopped}"
    );
    assert_eq!(calls.writes.load(Ordering::SeqCst), 1);
    assert_eq!(calls.reads.load(Ordering::SeqCst), 1);
}

#[test]
fn restoration_policy_unknown_effect_cannot_dispatch_twice_after_restart() {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let source = primary(&owners, &fakes);
    let calls = Arc::new(Calls::default());
    install(&owners, &fakes, &calls);
    let job = submit(&owners, &fakes, &request(&source, "unknown", true));
    fakes.begin(Script {
        perform: "retryRestoreUnknown".into(),
        ..Default::default()
    });
    let unknown = run(&owners, &fakes, &job);
    assert_eq!(
        unknown["result"]["state"], "waitingForRecovery",
        "{unknown}"
    );
    assert_eq!(unknown["result"]["outcomeUnknown"], true);
    let before = fs::read(root.join("store/jobs").join(&job).join("journal.jsonl")).unwrap();
    drop(owners);
    let restarted = Owners::open(&root, &fakes);
    install(&restarted, &fakes, &calls);
    let _ = run(&restarted, &fakes, &job);
    let status = restarted.answer(
        &fakes,
        "job.status",
        json!({"jobId":job}).as_object().unwrap(),
    );
    assert_eq!(status["result"]["state"], "waitingForRecovery", "{status}");
    assert_eq!(status["result"]["outcomeUnknown"], true);
    assert_eq!(calls.prepares.load(Ordering::SeqCst), 1);
    assert_eq!(calls.writes.load(Ordering::SeqCst), 1);
    assert_eq!(
        fs::read(root.join("store/jobs").join(&job).join("journal.jsonl")).unwrap(),
        before
    );
}
