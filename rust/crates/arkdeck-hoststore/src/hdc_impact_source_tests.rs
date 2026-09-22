//! The managed server's impact source over seams the test holds: the
//! server's identity and ownership facts, the critical Job gate over two
//! inventory reads, the devices and their private relations, the registered
//! `checkserver` bracket, and every leg whose failure leaves the impact
//! unavailable.
use super::*;
use arkdeck_provider_hdc::DispatchFailure;
use std::collections::VecDeque;
use std::net::{Ipv4Addr, SocketAddrV4};
use std::sync::Mutex;

const ENDPOINT: &str = "127.0.0.1:8710";

/// A tool the test may pin: the system shell (root-owned, not writable).
fn shell() -> StatusExecutable {
    let path = std::fs::canonicalize("/bin/sh").unwrap();
    StatusExecutable {
        sha256: sha256_hex(&std::fs::read(&path).unwrap()),
        path: path.to_string_lossy().into_owned(),
    }
}

fn receipt(executable: &StatusExecutable, pid: i32) -> ServerIdentityReceipt {
    ServerIdentityReceipt {
        pid,
        start_seconds: 100,
        start_microseconds: 23,
        executable_path: executable.path.clone().into(),
        executable_sha256: executable.sha256.clone(),
        endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8710),
    }
}

fn launch(executable: &StatusExecutable) -> ManagedLaunch {
    ManagedLaunch {
        pid: 42,
        start_seconds: 100,
        start_microseconds: 23,
        executable_path: executable.path.clone(),
        executable_sha256: executable.sha256.clone(),
        arguments: ["-s", ENDPOINT, "-m"].map(str::to_owned).to_vec(),
    }
}

fn observed(receipt: &ServerIdentityReceipt) -> IdentityObservation {
    IdentityObservation::Observed {
        generation: 100_000_023,
        identity: Some(receipt.clone()),
    }
}

/// Answers the identity observations in order, then no family.
struct Identity(Mutex<VecDeque<IdentityObservation>>);

impl Identity {
    fn new(observations: Vec<IdentityObservation>) -> Self {
        Self(Mutex::new(observations.into()))
    }
}

impl IdentityObserver for Identity {
    fn observe(&self, _: &StatusExecutable, endpoint: &str) -> IdentityObservation {
        assert_eq!(endpoint, ENDPOINT);
        self.0
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or(IdentityObservation::Unsupported("no family".into()))
    }
}

struct Signed;

impl SignatureInspector for Signed {
    fn inspect(&self, _: &Path) -> std::io::Result<Value> {
        Ok(
            json!({"state": "adHoc", "identifier": "hdc", "teamIdentifier": null,
            "platformTrust": "unverified", "executionAssessment": "notPerformed"}),
        )
    }
}

struct Verifies(bool);

impl ManagedProcessVerifier for Verifies {
    fn verifies(&self, _: &ServerIdentityReceipt, arguments: &[String]) -> bool {
        assert_eq!(arguments, ["-s", ENDPOINT, "-m"]);
        self.0
    }
}

/// Records every plan and answers each with the same receipt.
struct Dispatch {
    receipt: Receipt,
    plans: Mutex<Vec<ProcessPlan>>,
}

impl Dispatch {
    fn answering(exit_status: i32, stdout: &[u8], stderr: &[u8]) -> Self {
        Self {
            receipt: Receipt {
                exit_status,
                stdout: stdout.to_vec(),
                stderr: stderr.to_vec(),
                truncated: false,
                duration: Duration::from_millis(5),
            },
            plans: Mutex::new(Vec::new()),
        }
    }

    fn arguments(&self) -> Vec<Vec<String>> {
        self.plans
            .lock()
            .unwrap()
            .iter()
            .map(|plan| plan.arguments.clone())
            .collect()
    }
}

impl HdcDispatch for Dispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        self.plans.lock().unwrap().push(plan.clone());
        Ok(self.receipt.clone())
    }
}

fn job(id: &str, state: &str, unknown: bool, residues: i64) -> CurrentJob {
    CurrentJob {
        job_id: id.into(),
        state: state.into(),
        outcome_unknown: unknown,
        residues,
    }
}

/// Answers each read in order, then the last answer again.
struct Reads<T: Clone>(Mutex<VecDeque<Result<T, String>>>);

impl<T: Clone> Reads<T> {
    fn new(answers: Vec<Result<T, String>>) -> Self {
        Self(Mutex::new(answers.into()))
    }

    fn next(&self) -> Result<T, String> {
        let mut answers = self.0.lock().unwrap();
        if answers.len() > 1 {
            answers.pop_front().unwrap()
        } else {
            answers.front().cloned().unwrap()
        }
    }
}

impl SupervisorState for Reads<Option<SupervisedServer>> {
    fn state(&self, _endpoint: &str) -> Option<SupervisedServer> {
        self.next().unwrap()
    }
}

struct Legs {
    executable: StatusExecutable,
    identity: Identity,
    verifier: Verifies,
    launch: Option<ManagedLaunch>,
    supervisor: Reads<Option<SupervisedServer>>,
    dispatch: Dispatch,
    jobs: Reads<Vec<CurrentJob>>,
    targets: Reads<Vec<Value>>,
    devices: Reads<DeviceReading>,
}

impl Legs {
    fn new() -> Self {
        Self {
            executable: shell(),
            identity: Identity::new(Vec::new()),
            verifier: Verifies(true),
            launch: None,
            supervisor: Reads::new(vec![Ok(None)]),
            dispatch: Dispatch::answering(23, b"", b"unregistered fixture output\n"),
            jobs: Reads::new(vec![Ok(Vec::new())]),
            targets: Reads::new(vec![Ok(Vec::new())]),
            devices: Reads::new(vec![Ok(DeviceReading {
                generation: 1,
                rows: Vec::new(),
            })]),
        }
    }

    /// Runs `body` over the impact source these legs compose.
    fn with_source<T>(&self, body: impl FnOnce(&dyn ImpactSource) -> T) -> T {
        let launch = || self.launch.clone();
        let jobs = || self.jobs.next();
        let targets = || self.targets.next();
        let devices = || self.devices.next();
        let source = ManagedServerImpact {
            executable: self.executable.clone(),
            endpoint: ENDPOINT.into(),
            launch: &launch,
            supervisor: Some(&self.supervisor),
            identity: &self.identity,
            signature: &Signed,
            verifier: &self.verifier,
            dispatch: &self.dispatch,
            jobs: &jobs,
            targets: &targets,
            devices: &devices,
        };
        assert_eq!(source.endpoint_reference(), server_endpoint_ref(ENDPOINT));
        body(&source)
    }

    fn read(&self) -> Result<ImpactReading, String> {
        self.with_source(|source| source.read_impact())
    }

    fn server(&self) -> ServerObservation {
        let launch = || self.launch.clone();
        let none = || -> Result<Vec<CurrentJob>, String> { Err("unused".into()) };
        let empty = || -> Result<Vec<Value>, String> { Err("unused".into()) };
        let devices = || -> Result<DeviceReading, String> { Err("unused".into()) };
        ManagedServerImpact {
            executable: self.executable.clone(),
            endpoint: ENDPOINT.into(),
            launch: &launch,
            supervisor: Some(&self.supervisor),
            identity: &self.identity,
            signature: &Signed,
            verifier: &self.verifier,
            dispatch: &self.dispatch,
            jobs: &none,
            targets: &empty,
            devices: &devices,
        }
        .observe_server()
    }
}

#[test]
fn an_executable_without_an_identity_family_proves_no_server() {
    let legs = Legs::new();
    let reading = legs.read().unwrap();
    let executable = shell();
    assert_eq!(
        Value::Object(reading.impact.value().clone()),
        json!({
            "serverEndpointRef": server_endpoint_ref(ENDPOINT), "endpoint": ENDPOINT,
            "serverOwnership": "unknown", "serverGeneration": null,
            "serverHealth": "unknown", "serverVersion": null,
            "tool": {"reference": null, "executablePath": executable.path,
                "source": "runtimeConfiguration", "sha256": executable.sha256,
                "signature": {"state": "adHoc", "identifier": "hdc", "teamIdentifier": null,
                    "platformTrust": "unverified", "executionAssessment": "notPerformed"},
                "version": null, "trust": "unverified"},
            "affectedTargetIds": [], "affectedJobIds": [], "detectedOtherClientIds": [],
            "otherClientsMayExist": true, "affectedDeviceObservations": [],
            "criticalJobGate": {"state": "clear", "blocking": [], "reasonCode": null},
            "interruption": {"kind": "hdcEndpointUnavailable", "affectsAllParticipants": true},
            "recovery": {"kind": "statusThenReconcile", "replayAllowed": false},
        })
    );
    assert!(reading.relations.is_empty());
    assert_eq!(
        reading.blocker.as_deref(),
        Some("hdc.serverIdentityUnproven")
    );
    // Commandless: nothing was dispatched.
    assert!(legs.dispatch.arguments().is_empty());
}

#[test]
fn the_managed_launch_owns_the_identity_it_observes_on_both_sides() {
    let executable = shell();
    let identity = receipt(&executable, 42);
    for (verified, launched, ownership) in [
        (true, true, "arkDeckManaged"),
        (false, true, "unknown"),
        (true, false, "unknown"),
    ] {
        let mut legs = Legs::new();
        legs.identity = Identity::new(vec![observed(&identity), observed(&identity)]);
        legs.verifier = Verifies(verified);
        legs.launch = launched.then(|| launch(&executable));
        let reading = legs.read().unwrap();
        let impact = reading.impact.value();
        assert_eq!(
            impact["serverOwnership"], ownership,
            "{verified} {launched}"
        );
        assert_eq!(impact["serverGeneration"], "100000023");
        // A commandless identity proves no health.
        assert_eq!(impact["serverHealth"], "unknown");
        assert_eq!(impact["serverVersion"], Value::Null);
        assert_eq!(reading.blocker.as_deref(), Some("hdc.serverHealthUnproven"));
    }
    // The identity of another executable or endpoint is no generation.
    let mut legs = Legs::new();
    let mut foreign = identity.clone();
    foreign.executable_sha256 = "0".repeat(64);
    legs.identity = Identity::new(vec![observed(&foreign), observed(&foreign)]);
    legs.launch = Some(launch(&executable));
    let reading = legs.read().unwrap();
    assert_eq!(reading.impact.value()["serverGeneration"], Value::Null);
    assert_eq!(reading.impact.value()["serverOwnership"], "unknown");
}

#[test]
fn an_identity_that_changed_during_the_reading_leaves_no_server_facts() {
    let executable = shell();
    let mut legs = Legs::new();
    legs.identity = Identity::new(vec![
        observed(&receipt(&executable, 42)),
        observed(&receipt(&executable, 43)),
    ]);
    legs.launch = Some(launch(&executable));
    let reading = legs.read().unwrap();
    let impact = reading.impact.value();
    assert_eq!(impact["serverGeneration"], Value::Null);
    assert_eq!(impact["serverOwnership"], "unknown");
    assert_eq!(impact["serverHealth"], "unknown");
    assert_eq!(reading.blocker.as_deref(), Some("hdc.serverFactsDrifted"));
}

#[test]
fn inventory_that_changed_or_a_device_without_a_relation_leaves_the_gate_unknown() {
    // Jobs read differently on the two sides of the device observation.
    let mut legs = Legs::new();
    legs.jobs = Reads::new(vec![
        Ok(vec![job("job-1", "running", false, 0)]),
        Ok(vec![
            job("job-2", "queued", false, 0),
            job("job-1", "running", false, 0),
        ]),
    ]);
    let impact = legs.read().unwrap().impact;
    assert_eq!(impact.value()["affectedJobIds"], json!(["job-1", "job-2"]));
    assert_eq!(
        impact.value()["criticalJobGate"],
        json!({"state": "unknown", "reasonCode": "hdc.participantInventoryUnproven",
            "blocking": [
                {"jobId": "job-1", "stepId": null, "state": "running",
                    "safeBoundary": "blocked", "recovery": "waitForJob"},
                {"jobId": "job-2", "stepId": null, "state": "queued",
                    "safeBoundary": "blocked", "recovery": "waitForJob"}]})
    );
    // Targets read differently: every durable Target after is affected.
    let mut legs = Legs::new();
    legs.targets = Reads::new(vec![
        Ok(vec![json!({"targetID": "TGT-b"})]),
        Ok(vec![
            json!({"targetID": "TGT-b"}),
            json!({"targetID": "TGT-a"}),
        ]),
    ]);
    let impact = legs.read().unwrap().impact;
    assert_eq!(
        impact.value()["affectedTargetIds"],
        json!(["TGT-a", "TGT-b"])
    );
    assert_eq!(impact.value()["criticalJobGate"]["state"], "unknown");
    // Devices: rows in identity order, their relations private and sorted,
    // one without a relation unproved.
    let relation = UsbRelation {
        serial: "150100424a544e4600".into(),
        location: "100".into(),
        attachment_id: 17,
        vendor_id: 0x2207,
        product_id: 0x5000,
    };
    let mut legs = Legs::new();
    legs.devices = Reads::new(vec![Ok(DeviceReading {
        generation: 7,
        rows: vec![
            DeviceRow {
                observation_id: "obs-b".into(),
                state: "Connected".into(),
                relation: Some(relation.clone()),
            },
            DeviceRow {
                observation_id: "obs-a".into(),
                state: "Unauthorized".into(),
                relation: None,
            },
            DeviceRow {
                observation_id: "obs-c".into(),
                state: "Offline".into(),
                relation: None,
            },
        ],
    })]);
    let reading = legs.read().unwrap();
    assert_eq!(
        reading.impact.value()["affectedDeviceObservations"],
        json!([
            {"observationId": "obs-a", "generation": "7",
                "authorization": "unauthorized", "health": "unknown"},
            {"observationId": "obs-b", "generation": "7",
                "authorization": "authorized", "health": "connected"},
            {"observationId": "obs-c", "generation": "7",
                "authorization": "unknown", "health": "offline"},
        ])
    );
    assert_eq!(
        reading.relations,
        [json!({"observationId": "obs-b", "generation": "7",
            "serial": "150100424a544e4600", "location": "100", "attachmentId": "17",
            "vendorId": 0x2207, "productId": 0x5000})]
    );
    assert_eq!(
        reading.impact.value()["criticalJobGate"],
        json!({"state": "unknown", "blocking": [],
            "reasonCode": "hdc.participantInventoryUnproven"})
    );
    // Every device proved: the gate is clear.
    let mut legs = Legs::new();
    legs.devices = Reads::new(vec![Ok(DeviceReading {
        generation: 7,
        rows: vec![DeviceRow {
            observation_id: "obs-b".into(),
            state: "Connected".into(),
            relation: Some(relation),
        }],
    })]);
    assert_eq!(
        legs.read().unwrap().impact.value()["criticalJobGate"]["state"],
        "clear"
    );
}

#[test]
fn current_jobs_block_the_gate_with_the_recovery_each_needs() {
    let mut legs = Legs::new();
    let jobs = vec![
        job("job-c", "succeeded", true, 0),
        job("job-a", "failed", false, 2),
        job("job-b", "running", false, 0),
    ];
    legs.jobs = Reads::new(vec![Ok(jobs)]);
    let impact = legs.read().unwrap().impact;
    assert_eq!(
        impact.value()["criticalJobGate"],
        json!({"state": "blocked", "reasonCode": "hdc.currentJobs", "blocking": [
            {"jobId": "job-a", "stepId": null, "state": "failed",
                "safeBoundary": "blocked", "recovery": "continueCleanup"},
            {"jobId": "job-b", "stepId": null, "state": "running",
                "safeBoundary": "blocked", "recovery": "waitForJob"},
            {"jobId": "job-c", "stepId": null, "state": "succeeded",
                "safeBoundary": "blocked", "recovery": "reconcileJob"}]})
    );
}

#[test]
fn any_failed_leg_leaves_the_impact_unavailable() {
    let mut legs = Legs::new();
    legs.devices = Reads::new(vec![Err("empty observation output".into())]);
    assert_eq!(legs.read().unwrap_err(), "empty observation output");
    let mut legs = Legs::new();
    legs.jobs = Reads::new(vec![Err("Job inventory is unreadable".into())]);
    assert!(legs.read().is_err());
    let mut legs = Legs::new();
    legs.targets = Reads::new(vec![Ok(Vec::new()), Err("Target storage".into())]);
    assert!(legs.read().is_err());
    let mut legs = Legs::new();
    legs.executable.sha256 = "0".repeat(64);
    assert!(legs.read().is_err());
    // A Target record without an exact identity makes no valid impact.
    let mut legs = Legs::new();
    legs.targets = Reads::new(vec![Ok(vec![json!({"targetID": "not an id"})])]);
    assert!(legs.read().is_err());
}

#[test]
fn the_registered_family_proves_health_through_a_bracketed_checkserver() {
    let healthy = b"Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d\n";
    let registered = || {
        let mut legs = Legs::new();
        legs.executable.sha256 = REGISTERED_3_2_0D.into();
        legs
    };
    let identity = receipt(&shell(), 42);
    let mut legs = registered();
    legs.identity = Identity::new(vec![observed(&identity), observed(&identity)]);
    legs.dispatch = Dispatch::answering(0, healthy, b"");
    assert_eq!(
        legs.server(),
        ServerObservation {
            identity: Some(identity.clone()),
            health: "healthy",
            version: Some("3.2.0d".into()),
            reason: None,
        }
    );
    assert_eq!(legs.dispatch.arguments(), [["checkserver"]]);
    assert_eq!(
        legs.dispatch.plans.lock().unwrap()[0].timeout,
        Duration::from_secs(10)
    );
    let unavailable = ServerObservation {
        identity: None,
        health: "unknown",
        version: None,
        reason: Some("hdc.registeredHealthObservationUnavailable"),
    };
    for (dispatch, second) in [
        // Another version pair is outside the registered family.
        (
            Dispatch::answering(
                0,
                b"Client version:Ver: 3.2.0d, server version:Ver: 3.2.0f\n",
                b"",
            ),
            observed(&identity),
        ),
        (Dispatch::answering(1, healthy, b""), observed(&identity)),
        (
            Dispatch::answering(0, healthy, b"warning\n"),
            observed(&identity),
        ),
        // The identity changed across the command.
        (
            Dispatch::answering(0, healthy, b""),
            observed(&receipt(&shell(), 43)),
        ),
    ] {
        let mut legs = registered();
        legs.identity = Identity::new(vec![observed(&identity), second]);
        legs.dispatch = dispatch;
        assert_eq!(legs.server(), unavailable);
    }
    // No identity first: nothing runs.
    let legs = registered();
    assert_eq!(legs.server(), unavailable);
    assert!(legs.dispatch.arguments().is_empty());
}

/// Swift's `RegisteredHealthyServer` (`ControlActionWithHostContractTests`),
/// the seam its with-host restart frames were recorded through: the
/// production reading of everything else, then what only the registered
/// 3.2.0d server proves (a `checkserver` in its healthy family between two
/// identity observations, which would run an HDC) — generation 100000023,
/// healthy, version 3.2.0d and that tool version — and no blocker. Tests
/// only: no composition reads through it.
struct RegisteredHealthyServer<'a>(&'a dyn ImpactSource);

impl ImpactSource for RegisteredHealthyServer<'_> {
    fn endpoint_reference(&self) -> String {
        self.0.endpoint_reference()
    }

    fn read_impact(&self) -> Result<ImpactReading, String> {
        let reading = self.0.read_impact()?;
        let mut facts = reading.impact.value().clone();
        facts.insert("serverGeneration".into(), json!("100000023"));
        facts.insert("serverHealth".into(), json!("healthy"));
        facts.insert("serverVersion".into(), json!("3.2.0d"));
        if let Some(Value::Object(tool)) = facts.get_mut("tool") {
            tool.insert("version".into(), json!("3.2.0d"));
        }
        Ok(ImpactReading {
            impact: Impact::new(facts).map_err(|error| error.message)?,
            relations: reading.relations,
            blocker: None,
        })
    }
}

#[test]
fn only_a_proved_healthy_server_previews_a_restart_whose_approval_is_requested() {
    use crate::hdc_control_action::{HdcControlActions, OwnerContext};
    use std::os::unix::fs::DirBuilderExt;
    let directory = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "hdc-impact-source-restart-{:032x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    ));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&directory)
        .unwrap();
    struct Remove(std::path::PathBuf);
    impl Drop for Remove {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _remove = Remove(directory.clone());
    let owner = HdcControlActions::open(
        &directory,
        OwnerContext {
            epoch: "epoch".into(),
            catalog: "a".repeat(64),
            // 2026-09-19T00:00:00.000Z, Swift's with-host clock.
            clock: Box::new(|| Some(1_789_776_000_000)),
            uuid: Box::new(crate::snapshot_pager::uuid),
        },
    )
    .unwrap();
    let intent = |request: &str| {
        json!({"action": "restart", "actionRequestId": request,
            "serverEndpointRef": server_endpoint_ref(ENDPOINT),
            "expectedServerGeneration": "100000023"})
        .as_object()
        .unwrap()
        .clone()
    };
    let tuple = |record: &Value| {
        [
            record["controlActionId"].as_str().unwrap().to_owned(),
            record["preview"]["previewId"].as_str().unwrap().to_owned(),
            record["preview"]["previewDigest"]
                .as_str()
                .unwrap()
                .to_owned(),
        ]
    };
    // An executable without an identity family, as the fixture HDC and the
    // isolated daemon's managed fake are, over nothing affected.
    let legs = Legs::new();
    legs.with_source(|production| {
        // The production reading proves no server: the preview is blocked
        // and its restart is not eligible, as Swift's daemon answers.
        let blocked = owner.preview(&intent("fixture"), production).unwrap();
        assert_eq!(blocked["state"], "blocked");
        assert_eq!(blocked["blockerReasonCode"], "hdc.serverIdentityUnproven");
        let [id, preview, digest] = tuple(&blocked);
        let error = owner
            .restart(&id, &preview, &digest, production)
            .unwrap_err();
        assert_eq!(
            (error.code.as_str(), error.message.as_str()),
            (
                "admissionDenied",
                "the control action is not eligible for impact approval"
            )
        );
        // Over Swift's seam the same reading is a ready preview, and its
        // restart requests the approval.
        let healthy = RegisteredHealthyServer(production);
        let ready = owner.preview(&intent("healthy"), &healthy).unwrap();
        assert_eq!(ready["state"], "previewReady");
        assert_eq!(ready["preview"]["serverHealth"], "healthy");
        assert_eq!(ready["preview"]["tool"]["version"], "3.2.0d");
        assert_eq!(
            ready["preview"]["tool"]["signature"],
            json!({"state": "adHoc", "identifier": "hdc", "teamIdentifier": null,
                "platformTrust": "unverified", "executionAssessment": "notPerformed"})
        );
        let [id, preview, digest] = tuple(&ready);
        let awaiting = owner.restart(&id, &preview, &digest, &healthy).unwrap();
        assert_eq!(awaiting["state"], "awaitingImpactApproval");
        assert_eq!(awaiting["humanAction"]["status"], "waiting");
        assert_eq!(awaiting["dispatchCount"], 0);
    });
    // Nothing ran the executable: no command at all, so no `kill`.
    assert!(legs.dispatch.arguments().is_empty());
}

#[test]
fn supervisor_ownership_requires_unchanged_exact_healthy_generation() {
    let expected = SupervisedServer {
        endpoint: ENDPOINT.into(),
        healthy: true,
        generation: 100_000_023,
        ark_deck_managed: true,
    };
    let cases = [
        (
            Some(expected.clone()),
            Some(expected.clone()),
            "arkDeckManaged",
        ),
        (None, Some(expected.clone()), "unknown"),
        (Some(expected.clone()), None, "unknown"),
        (
            Some(expected.clone()),
            Some(SupervisedServer {
                generation: 100_000_024,
                ..expected.clone()
            }),
            "unknown",
        ),
        (
            Some(SupervisedServer {
                healthy: false,
                ..expected.clone()
            }),
            Some(SupervisedServer {
                healthy: false,
                ..expected.clone()
            }),
            "unknown",
        ),
        (
            Some(SupervisedServer {
                ark_deck_managed: false,
                ..expected.clone()
            }),
            Some(SupervisedServer {
                ark_deck_managed: false,
                ..expected.clone()
            }),
            "unknown",
        ),
        (
            Some(SupervisedServer {
                endpoint: "127.0.0.1:8711".into(),
                ..expected.clone()
            }),
            Some(SupervisedServer {
                endpoint: "127.0.0.1:8711".into(),
                ..expected.clone()
            }),
            "unknown",
        ),
    ];
    for (before, after, ownership) in cases {
        let mut legs = Legs::new();
        let identity = receipt(&legs.executable, 42);
        legs.identity = Identity::new(vec![observed(&identity), observed(&identity)]);
        legs.supervisor = Reads::new(vec![Ok(before), Ok(after)]);
        let reading = legs.read().unwrap();
        assert_eq!(reading.impact.value()["serverOwnership"], ownership);
        // Ownership does not supply registered server health or bypass it.
        assert_eq!(reading.blocker.as_deref(), Some("hdc.serverHealthUnproven"));
        assert!(legs.dispatch.arguments().is_empty());
    }
}
