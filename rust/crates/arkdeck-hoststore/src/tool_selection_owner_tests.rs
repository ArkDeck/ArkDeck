//! Coordinator behavior using retained Swift facts and private fixture stores.
use super::*;
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::PathBuf;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicU64, Ordering},
};

const NOW: u64 = 1_788_220_800_000;
fn fields(v: Value) -> Map<String, Value> {
    v.as_object().unwrap().clone()
}
fn fixture_preview() -> Map<String, Value> {
    let root =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/tool-selection-store");
    let cases: Value = serde_json::from_slice(&fs::read(root.join("cases.json")).unwrap()).unwrap();
    let record: Value = serde_json::from_slice(
        &fs::read(root.join(cases["oracle-awaiting"]["file"].as_str().unwrap())).unwrap(),
    )
    .unwrap();
    record["preview"].as_object().unwrap().clone()
}
fn projection(f: &Value) -> Value {
    json!({"schemaVersion":"arkdeck.runtime-tool/1","kind":"hdc","platform":"macos","toolRef":f["toolRef"],"generation":f["recordGeneration"],
        "contentDigest":f["contentSHA256"],"executableSHA256":f["executableSHA256"],"trust":{
            "policy":f["trust"]["policy"],"registeredIdentity":true,"signature":f["signature"]["state"],"toolVersion":f["version"],
            "signingIdentifier":f["signature"]["identifier"],"teamIdentifier":f["signature"]["teamIdentifier"],
            "codeDirectoryIdentitySHA256":f["signature"]["codeDirectoryIdentitySHA256"],"profileReferences":f["trust"]["profileReferences"]}})
}
struct Registry {
    preview: Map<String, Value>,
    outcome: Mutex<DurableSelectionOutcome>,
    prepares: AtomicU64,
    fail_candidate: AtomicU64,
    fail_mode: AtomicU64,
}
impl ToolSelectionRegistry for Arc<Registry> {
    fn candidate(
        &self,
        tool: &str,
        generation: u64,
        _: Option<&str>,
    ) -> Result<SelectionCandidate, WireError> {
        if self.fail_candidate.load(Ordering::SeqCst) > 0 {
            return Err(refused("factsDrifted", "fixture identity changed"));
        }
        assert_eq!(tool, self.preview["newTool"]["toolRef"].as_str().unwrap());
        assert_eq!(generation, 1);
        Ok(SelectionCandidate {
            selection: arkdeck_bootstrap::SelectionSnapshot {
                active_tool_ref: self.preview["oldTool"]["toolRef"].as_str().unwrap().into(),
                active_generation: 1,
                active_tool: projection(&self.preview["oldTool"]),
                pending_action_id: None,
                pending_tool_ref: None,
            },
            new_tool: projection(&self.preview["newTool"]),
        })
    }
    fn prepare(
        &self,
        action: &str,
        tool: &str,
        generation: u64,
    ) -> Result<StartupSelection, WireError> {
        self.prepares.fetch_add(1, Ordering::SeqCst);
        *self.outcome.lock().unwrap() = DurableSelectionOutcome::Pending;
        Ok(StartupSelection {
            tool_ref: tool.into(),
            active_generation: generation,
            pending_action_id: Some(action.into()),
            executable: "/fixture/new-hdc".into(),
            executable_sha256: "b".repeat(64),
            dependencies: vec![],
        })
    }
    fn fail(&self, _: &str, reason: &str) -> Result<(), WireError> {
        if self.fail_mode.load(Ordering::SeqCst) == 1 {
            return Err(record_unreadable("fixture fail write refused"));
        }
        *self.outcome.lock().unwrap() = DurableSelectionOutcome::Failed {
            active_tool_ref: self.preview["oldTool"]["toolRef"].as_str().unwrap().into(),
            active_generation: 1,
            reason_code: reason.into(),
        };
        if self.fail_mode.load(Ordering::SeqCst) == 2 {
            return Err(record_unreadable("fixture fail write acknowledgment lost"));
        }
        Ok(())
    }
    fn outcome(&self, _: &str) -> Result<DurableSelectionOutcome, WireError> {
        Ok(self.outcome.lock().unwrap().clone())
    }
    fn acknowledge(&self, _: &str) -> Result<(), WireError> {
        *self.outcome.lock().unwrap() = DurableSelectionOutcome::Absent;
        Ok(())
    }
}
struct Source {
    reading: Mutex<ImpactReading>,
    reads: AtomicU64,
}
impl ImpactSource for Source {
    fn endpoint_reference(&self) -> String {
        self.reading.lock().unwrap().impact.value()["serverEndpointRef"]
            .as_str()
            .unwrap()
            .into()
    }
    fn read_impact(&self) -> Result<ImpactReading, String> {
        self.reads.fetch_add(1, Ordering::SeqCst);
        Ok(self.reading.lock().unwrap().clone())
    }
}
struct Fixture {
    root: PathBuf,
    owner: ToolSelectionActions,
    registry: Arc<Registry>,
    source: Source,
    clock: Arc<AtomicU64>,
    jobs: crate::JobStore,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "selection-owner-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let dir = HostDirectory::open(&root).unwrap();
        dir.private_child("actions").unwrap();
        dir.private_child("jobs").unwrap();
        let preview = fixture_preview();
        let hdc_keys = [
            "serverEndpointRef",
            "endpoint",
            "serverOwnership",
            "serverGeneration",
            "serverHealth",
            "serverVersion",
            "tool",
            "affectedTargetIds",
            "affectedJobIds",
            "detectedOtherClientIds",
            "otherClientsMayExist",
            "affectedDeviceObservations",
            "criticalJobGate",
            "interruption",
            "recovery",
        ];
        let source = Source {
            reading: Mutex::new(ImpactReading {
                impact: Impact::new(
                    hdc_keys
                        .into_iter()
                        .map(|k| (k.into(), preview[k].clone()))
                        .collect(),
                )
                .unwrap(),
                relations: vec![],
                blocker: None,
            }),
            reads: AtomicU64::new(0),
        };
        let registry = Arc::new(Registry {
            preview,
            outcome: Mutex::new(DurableSelectionOutcome::Absent),
            prepares: AtomicU64::new(0),
            fail_candidate: AtomicU64::new(0),
            fail_mode: AtomicU64::new(0),
        });
        let clock = Arc::new(AtomicU64::new(NOW));
        let c = clock.clone();
        let mut context = OwnerContext::production().unwrap();
        context.clock = Box::new(move || Some(c.load(Ordering::SeqCst)));
        let owner =
            ToolSelectionActions::open(&root.join("actions"), context, Box::new(registry.clone()))
                .unwrap();
        let jobs = crate::JobStore::open_owner(&root.join("jobs")).unwrap();
        Self {
            root,
            owner,
            registry,
            source,
            clock,
            jobs,
        }
    }
    fn request(&self) -> Map<String, Value> {
        fields(
            json!({"actionRequestId":"fixture-request","tool":self.registry.preview["newTool"]["toolRef"],"expectedActiveGeneration":"1"}),
        )
    }
    fn waiting(&self) -> Value {
        self.owner.select(&self.request(), &self.source).unwrap()
    }
    fn challenge(&self) -> (String, String, String) {
        let row = self.waiting();
        let human = &row["humanAction"];
        let challenge = self
            .owner
            .issue_interactive_challenge(
                human["actionId"].as_str().unwrap(),
                human["resumeReference"].as_str().unwrap(),
            )
            .unwrap();
        (
            row["controlActionId"].as_str().unwrap().into(),
            human["resumeReference"].as_str().unwrap().into(),
            challenge["challenge"].as_str().unwrap().into(),
        )
    }
    fn consume(
        &self,
        t: &(String, String, String),
        driver: &dyn ToolSelectionDriver,
    ) -> Result<Value, WireError> {
        self.owner
            .consume_interactive_challenge(&t.0, &t.1, &t.2, &self.jobs, &self.source, driver)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
struct Never;
impl ToolSelectionDriver for Never {
    fn restart_selected(
        &self,
        _: &StartupSelection,
        _: &ImpactReading,
        _: &ToolSelectionAudit<'_>,
    ) -> Result<(), WireError> {
        panic!("no dispatch allowed")
    }
}
struct Failed;
impl ToolSelectionDriver for Failed {
    fn restart_selected(
        &self,
        _: &StartupSelection,
        _: &ImpactReading,
        _: &ToolSelectionAudit<'_>,
    ) -> Result<(), WireError> {
        Err(refused("operationFailed", "fixture pre-launch failure"))
    }
}

#[test]
fn select_observes_twice_and_deduplicates_without_registry_mutation() {
    let f = Fixture::new();
    let row = f.waiting();
    assert_eq!(row["state"], "awaitingImpactApproval");
    assert_eq!(f.source.reads.load(Ordering::SeqCst), 2);
    assert_eq!(row, f.waiting());
    assert_eq!(f.registry.prepares.load(Ordering::SeqCst), 0);
    assert_eq!(f.source.reads.load(Ordering::SeqCst), 2);
    let mut changed = f.request();
    changed.insert("expectedActiveGeneration".into(), json!("2"));
    assert_eq!(
        f.owner.select(&changed, &f.source).unwrap_err().code,
        "idempotencyConflict"
    );
}
#[test]
fn unavailable_facts_and_unhealthy_server_cannot_request_approval() {
    let f = Fixture::new();
    f.registry.fail_candidate.store(1, Ordering::SeqCst);
    assert_eq!(
        f.waiting()["blockerReasonCode"],
        "tool.selectionFactsUnavailable"
    );
    let f = Fixture::new();
    f.source.reading.lock().unwrap().blocker = Some("fixture.blocked".into());
    let row = f.waiting();
    assert_eq!(row["state"], "blocked");
    assert!(row["humanAction"].is_null());
}
#[test]
fn wrong_challenge_expiry_and_impact_drift_never_prepare_selection() {
    let f = Fixture::new();
    let mut c = f.challenge();
    c.2 = "ARKDECK-000000000".into();
    assert_eq!(
        f.consume(&c, &Never).unwrap_err().code,
        "impactApprovalChallengeMismatch"
    );
    f.clock.store(NOW + 120_001, Ordering::SeqCst);
    assert_eq!(
        f.consume(&c, &Never).unwrap_err().code,
        "impactApprovalChallengeExpired"
    );
    assert_eq!(f.registry.prepares.load(Ordering::SeqCst), 0);
    let f = Fixture::new();
    let c = f.challenge();
    f.source
        .reading
        .lock()
        .unwrap()
        .relations
        .push(json!({"changed":true}));
    assert_eq!(f.consume(&c, &Never).unwrap_err().code, "factsDrifted");
    assert_eq!(f.registry.prepares.load(Ordering::SeqCst), 0);
}
#[test]
fn final_interlock_refuses_before_any_selection_is_prepared() {
    let f = Fixture::new();
    let c = f.challenge();
    let _gate = f.jobs.acquire_hdc_lifecycle_interlock().unwrap();
    assert_eq!(f.consume(&c, &Never).unwrap_err().code, "resourceConflict");
    assert_eq!(f.registry.prepares.load(Ordering::SeqCst), 0);
}
#[test]
fn failure_before_launch_settles_zero_dispatch_and_releases_admission() {
    let f = Fixture::new();
    let c = f.challenge();
    let error = f.consume(&c, &Failed).unwrap_err();
    assert_eq!(error.code, "operationFailed");
    let p = &error.details.unwrap()["controlAction"];
    assert_eq!(p["state"], "failed");
    assert_eq!(p["dispatchCount"], 0);
    assert!(f.jobs.acquire_hdc_lifecycle_interlock().is_ok());
    assert_eq!(
        f.consume(&c, &Never).unwrap_err().code,
        "humanActionExpired"
    );
    assert_eq!(f.registry.prepares.load(Ordering::SeqCst), 1);
}
#[test]
fn registry_projection_has_swift_path_free_facts() {
    let p = fixture_preview();
    for name in ["oldTool", "newTool"] {
        assert_eq!(
            ToolFacts::registry_projection(&projection(&p[name]))
                .unwrap()
                .value(),
            p[name].as_object().unwrap()
        );
    }
}

struct Entered {
    wrong_hash: bool,
}
impl ToolSelectionDriver for Entered {
    fn restart_selected(
        &self,
        selected: &StartupSelection,
        reading: &ImpactReading,
        audit: &ToolSelectionAudit<'_>,
    ) -> Result<(), WireError> {
        let h = reading.impact.value();
        let id = "00000000-0000-4000-8000-000000000001";
        let generation = h["serverGeneration"]
            .as_str()
            .unwrap()
            .parse::<u64>()
            .unwrap();
        let scope = json!({"schemaVersion":1,"action":"restartConfirmedGeneration","endpoint":h["endpoint"],"generation":generation,"ownership":h["serverOwnership"],
            "affectedDeviceCoordinators":h["affectedTargetIds"],"affectedJobs":[],"otherClientDetection":{"kind":"unavailableExternalClientsMayStillExist","clients":[]},
            "expectedInterruption":"HDC requests using this endpoint will be interrupted.","recoveryPath":"Re-probe the shared endpoint and reconcile every affected Job."});
        let hash = arkdeck_contract::sha256_hex(&arkdeck_contract::canonical_json(&scope).unwrap());
        let mut preview = fields(scope);
        preview.remove("schemaVersion");
        preview.insert("previewId".into(), json!(id));
        preview.insert("scopeHash".into(), json!(hash));
        audit.append("impactPreview", id, Value::Object(preview))?;
        audit.append("confirmation",id,json!({"confirmationId":id,"previewId":id,"action":"restartConfirmedGeneration","endpoint":h["endpoint"],"generation":generation,"ownership":h["serverOwnership"],"scopeHash":hash}))?;
        audit.append("intent",id,json!({"stepId":id,"confirmationId":id,"action":"restartConfirmedGeneration","endpoint":h["endpoint"],"expectedGeneration":generation,"expectedOwnership":h["serverOwnership"],"impactSnapshotHash":hash}))?;
        let actual = json!({"stepId":id,"executable":selected.executable,"argv":["-s",h["endpoint"],"kill","-r"],"endpoint":h["endpoint"]});
        audit.append("actualCommand", id, actual.clone())?;
        let mut launch = fields(actual);
        launch.extend(fields(json!({"authorizedExecutable":selected.executable,"inodeLaunchPath":"/.vol/1/2","executableDevice":"1","executableInode":"2",
            "executableFileSize":1,"executableMode":"448","executableSha256":if self.wrong_hash {"c".repeat(64)} else {selected.executable_sha256.clone()}})));
        audit.append("launchWindowEntered", id, Value::Object(launch))?;
        Err(WireError {
            code: "recordUnreadable".into(),
            message: "fixture interrupted after launch".into(),
            details: None,
        })
    }
}
#[test]
fn entered_launch_freezes_old_graph_and_settles_only_from_registry_without_replay() {
    for success in [true, false] {
        let f = Fixture::new();
        let c = f.challenge();
        let row = f.consume(&c, &Entered { wrong_hash: false }).unwrap();
        assert_eq!(row["state"], "outcomeUnknown");
        assert_eq!(row["dispatchCount"], 1);
        assert_eq!(
            f.jobs.acquire_hdc_lifecycle_interlock().err().unwrap().code,
            "resourceConflict"
        );
        assert_eq!(
            f.jobs.admission_interlock().err().unwrap().code,
            "resourceConflict"
        );
        assert_eq!(
            f.owner.show(&c.0, &f.source).unwrap()["state"],
            "outcomeUnknown"
        );
        assert_eq!(f.registry.prepares.load(Ordering::SeqCst), 1);
        *f.registry.outcome.lock().unwrap() = if success {
            DurableSelectionOutcome::Succeeded {
                active_tool_ref: f.registry.preview["newTool"]["toolRef"]
                    .as_str()
                    .unwrap()
                    .into(),
                active_generation: 2,
            }
        } else {
            DurableSelectionOutcome::Failed {
                active_tool_ref: f.registry.preview["oldTool"]["toolRef"]
                    .as_str()
                    .unwrap()
                    .into(),
                active_generation: 1,
                reason_code: "tool.selectedStartupVerificationFailed".into(),
            }
        };
        assert_eq!(
            f.owner.show(&c.0, &f.source).unwrap()["state"],
            if success { "succeeded" } else { "failed" }
        );
        assert_eq!(
            *f.registry.outcome.lock().unwrap(),
            DurableSelectionOutcome::Absent
        );
        assert_eq!(
            f.consume(&c, &Never).unwrap_err().code,
            "humanActionExpired"
        );
        assert_eq!(f.registry.prepares.load(Ordering::SeqCst), 1);
    }
}
#[test]
fn wrong_selected_executable_hash_stops_before_launch_and_unfreezes_graph() {
    let f = Fixture::new();
    let c = f.challenge();
    let error = f.consume(&c, &Entered { wrong_hash: true }).unwrap_err();
    assert_eq!(error.details.unwrap()["controlAction"]["dispatchCount"], 0);
    assert!(f.jobs.admission_interlock().is_ok());
}
#[test]
fn missing_durable_outcome_remains_unknown_and_is_not_replayed() {
    let f = Fixture::new();
    let c = f.challenge();
    f.consume(&c, &Entered { wrong_hash: false }).unwrap();
    *f.registry.outcome.lock().unwrap() = DurableSelectionOutcome::Absent;
    assert_eq!(
        f.owner.show(&c.0, &f.source).unwrap_err().code,
        "recordUnreadable"
    );
    assert_eq!(f.owner.required(&c.0).unwrap().state, "outcomeUnknown");
    assert_eq!(f.registry.prepares.load(Ordering::SeqCst), 1);
}
#[test]
fn union_discovers_tool_action_and_human_approval_without_console_self_approval() {
    let f = Fixture::new();
    let root = HostDirectory::open(&f.root).unwrap();
    for name in ["controls", "humans", "agents"] {
        root.private_child(name).unwrap();
    }
    let mut context = OwnerContext::production().unwrap();
    context.clock = Box::new(|| Some(NOW));
    let tools = ToolSelectionActions::open(
        &f.root.join("actions"),
        context,
        Box::new(f.registry.clone()),
    )
    .unwrap();
    let controls = crate::ControlActionResources::open(&f.root.join("controls"))
        .unwrap()
        .with_tools(tools);
    let row = controls
        .answer("runtime.tool.select", &f.request(), Some(&f.source))
        .unwrap();
    let id = row["controlActionId"].as_str().unwrap();
    let listed = controls
        .answer(
            "control-action.list",
            &fields(json!({"kind":"runtimeToolSelection"})),
            Some(&f.source),
        )
        .unwrap();
    assert_eq!(listed["items"][0], row);
    assert_eq!(
        controls
            .answer(
                "control-action.show",
                &fields(json!({"controlAction":id})),
                Some(&f.source)
            )
            .unwrap(),
        row
    );
    let agents = crate::AgentExecutionStore::open(&f.root.join("agents")).unwrap();
    let humans = crate::HumanActionResources::open(&f.root.join("humans")).unwrap();
    let human = &row["humanAction"];
    let params = fields(json!({"humanAction":human["actionId"]}));
    assert_eq!(
        humans
            .answer("human-action.show", &params, &agents, Some(&controls))
            .unwrap(),
        *human
    );
    let params =
        fields(json!({"humanAction":human["actionId"],"resumeReference":human["resumeReference"]}));
    assert!(
        humans
            .resume_control_action("human-action.resume", &params, &agents, &controls)
            .unwrap()
            .is_ok()
    );
    assert_eq!(f.registry.prepares.load(Ordering::SeqCst), 0);
    let c = controls
        .issue_interactive_challenge(
            human["actionId"].as_str().unwrap(),
            human["resumeReference"].as_str().unwrap(),
        )
        .unwrap();
    assert_eq!(c["controlAction"]["kind"], "runtimeToolSelection");
}

#[test]
fn union_refuses_identity_shared_by_both_control_owners() {
    let f = Fixture::new();
    let root = HostDirectory::open(&f.root).unwrap();
    for name in ["controls", "hdc"] {
        root.private_child(name).unwrap();
    }
    let context = || OwnerContext {
        epoch: "fixture".into(),
        catalog: "a".repeat(64),
        clock: Box::new(|| Some(NOW)),
        uuid: Box::new(|| Ok("00000000-0000-4000-8000-000000000001".into())),
    };
    let tools = ToolSelectionActions::open(
        &f.root.join("actions"),
        context(),
        Box::new(f.registry.clone()),
    )
    .unwrap();
    let hdc = crate::HdcControlActions::open(&f.root.join("hdc"), context()).unwrap();
    let controls = crate::ControlActionResources::open(&f.root.join("controls"))
        .unwrap()
        .with_tools(tools)
        .with_hdc(hdc);
    let tool = controls
        .answer("runtime.tool.select", &f.request(), Some(&f.source))
        .unwrap();
    let generation = f.source.reading.lock().unwrap().impact.value()["serverGeneration"].clone();
    let hdc = controls
        .answer(
            "runtime.hdc.impact-preview",
            &fields(
                json!({"action":"restart","actionRequestId":"restart-request",
        "serverEndpointRef":f.source.endpoint_reference(),"expectedServerGeneration":generation}),
            ),
            Some(&f.source),
        )
        .unwrap();
    assert_eq!(tool["controlActionId"], hdc["controlActionId"]);
    assert_eq!(
        controls
            .answer(
                "control-action.show",
                &fields(json!({"controlAction":tool["controlActionId"]})),
                Some(&f.source)
            )
            .unwrap_err()
            .code,
        "recordUnreadable"
    );
    assert_eq!(
        controls
            .answer("control-action.list", &Map::new(), Some(&f.source))
            .unwrap_err()
            .code,
        "recordUnreadable"
    );
}

#[test]
fn failed_rollback_write_requires_readback_and_never_invents_settlement() {
    let f = Fixture::new();
    let c = f.challenge();
    f.registry.fail_mode.store(1, Ordering::SeqCst);
    let error = f.consume(&c, &Failed).unwrap_err();
    assert_eq!(error.code, "recordUnreadable");
    assert_eq!(
        error.details.unwrap()["controlAction"]["state"],
        "dispatchPrepared"
    );
    assert_eq!(
        *f.registry.outcome.lock().unwrap(),
        DurableSelectionOutcome::Pending
    );
    assert_eq!(f.owner.required(&c.0).unwrap().value()["dispatchCount"], 0);
    f.clock.store(NOW + 600_000, Ordering::SeqCst);
    assert_eq!(
        f.owner.show(&c.0, &f.source).unwrap()["state"],
        "dispatchPrepared"
    );
    assert_eq!(
        f.owner.list_records().unwrap()[0].state(),
        "dispatchPrepared"
    );
    assert_eq!(
        f.consume(&c, &Never).unwrap_err().code,
        "humanActionExpired"
    );
    assert_eq!(f.registry.prepares.load(Ordering::SeqCst), 1);
    let f = Fixture::new();
    let c = f.challenge();
    f.registry.fail_mode.store(2, Ordering::SeqCst);
    assert_eq!(f.consume(&c, &Failed).unwrap_err().code, "operationFailed");
    assert_eq!(f.owner.required(&c.0).unwrap().state, "failed");
}

#[test]
fn audit_read_failure_after_launch_keeps_admission_frozen_without_zero_dispatch_claim() {
    struct LostAudit<'a>(&'a Path);
    impl ToolSelectionDriver for LostAudit<'_> {
        fn restart_selected(
            &self,
            selected: &StartupSelection,
            reading: &ImpactReading,
            audit: &ToolSelectionAudit<'_>,
        ) -> Result<(), WireError> {
            let _ = Entered { wrong_hash: false }.restart_selected(selected, reading, audit);
            assert!(audit.entered());
            fs::rename(self.0.join("records"), self.0.join("records-unavailable")).unwrap();
            Err(record_unreadable("fixture lost the durable audit path"))
        }
    }
    let f = Fixture::new();
    let c = f.challenge();
    let path = f.root.join("actions");
    let error = f.consume(&c, &LostAudit(&path)).unwrap_err();
    assert_eq!(error.code, "recordUnreadable");
    assert!(error.details.is_none());
    assert!(f.jobs.admission_interlock().is_err());
    assert!(f.jobs.acquire_hdc_lifecycle_interlock().is_err());
    assert_eq!(f.registry.prepares.load(Ordering::SeqCst), 1);
}
