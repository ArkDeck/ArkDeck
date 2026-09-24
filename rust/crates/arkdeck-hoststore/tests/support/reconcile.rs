//! What the replays of Swift's device reconcile oracles share
//! (`DeviceReconcileOracleContractTests`, `ReadbackReconcileOracleContractTests`,
//! both over `HDCOracleFake` at the fixed root `support/debug_hap.rs`
//! rebuilds): a daemon composed over that root as the standalone daemon
//! composes it — its account-fixed Job root, the capability store inside it,
//! the Session owner, the Target owner and the fake's executable — started
//! again over the same root as Swift's oracle starts it (every owner opened
//! afresh, then `recoverActiveJobs`), each recorded request answered by the
//! Rust owner that serves it, and each recorded store snapshot compared file
//! by file.
use super::native_library::code_sign_helper;
use super::{OracleProbe, assert_store, debug_hap, document, fixed_now, fixed_precise_now};
use arkdeck_contract::{WireError, sha256_hex};
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, HdcComposition, JobAdmitter, JobPlanner,
    JobReconciler, JobResultReader, JobRunner, JobStore, MutationAuthority, MutationExecution,
    RecoveredJobs, RunCancellation, SessionPublisher, SessionStore, StorageClaims, TargetStore,
    list_cleanup_debt, recover_active_jobs,
};
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::{
    CodeSignHelper, DispatchFailure, HdcDispatch, ProcessDispatch, ProcessPlan, Receipt,
};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The owners one daemon start opens over the root.
pub struct Stores {
    pub targets: TargetStore,
    pub artifacts: ArtifactReadStore,
    pub jobs: JobStore,
    pub capabilities: CapabilityStore,
    pub sessions: SessionStore,
    pub holds: DeviceHolds,
    pub claims: StorageClaims,
}

/// A daemon over the root rebuilt from an oracle's fixture, composed as the
/// oracle composed its engine: with the code-sign helper its cases name, the
/// host receive root and the fixed child duration its provenance names.
pub struct Daemon {
    pub fixture: PathBuf,
    pub root: PathBuf,
    pub default_root: PathBuf,
    pub digest: String,
    pub provenance: Value,
    pub dispatch: ProcessDispatch,
    pub probe: OracleProbe,
    helper: Option<CodeSignHelper>,
    receive_root: Option<PathBuf>,
    stores: Option<Stores>,
}

/// Swift's `FixedDurationDispatcher` over the daemon's dispatch, where the
/// oracle fixed every child's reported duration; the dispatch unchanged
/// otherwise.
pub struct Timed<'a> {
    inner: &'a ProcessDispatch,
    seconds: Option<f64>,
}

impl HdcDispatch for Timed<'_> {
    fn mutation_identity_current(&self) -> bool {
        self.inner.mutation_identity_current()
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let mut receipt = self.inner.dispatch(plan)?;
        if let Some(seconds) = self.seconds {
            receipt.duration = Duration::from_secs_f64(seconds);
        }
        Ok(receipt)
    }
}

/// A control answer as the oracles record it: a refusal carries details
/// only when it has any.
pub fn answer(outcome: Result<Value, WireError>) -> Value {
    match outcome {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(error) => {
            let mut refusal = json!({"code": error.code, "message": error.message});
            if let Some(details) = error.details {
                refusal["details"] = Value::Object(details);
            }
            json!({"ok": false, "error": refusal})
        }
    }
}

fn proven() -> Map<String, Value> {
    Map::from_iter([
        ("phase".into(), json!("preAdmission")),
        ("newDispatchCount".into(), json!(0)),
    ])
}

impl Daemon {
    /// The root rebuilt from the oracle `name`, and the daemon's first
    /// start over it (nothing to recover yet). The caller holds
    /// [`debug_hap::exclusive`].
    pub fn open(name: &str) -> Self {
        let fixture = super::fixture(name);
        let provenance = document(&fixture, "provenance.json");
        let root = debug_hap::rebuild(&fixture);
        let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
        assert_eq!(provenance["hdcSHA256"], digest.as_str());
        let cases = document(&fixture, "cases.json");
        let mut daemon = Self {
            dispatch: ProcessDispatch::new(
                VerifiedTool::open(root.join("hdc"), &digest).unwrap(),
                None,
            ),
            probe: OracleProbe::new(&provenance),
            default_root: root.join("store"),
            helper: cases
                .get("codeSignHelper")
                .map(|_| code_sign_helper(&cases, &root)),
            receive_root: provenance["receiveRoot"].as_str().map(PathBuf::from),
            fixture,
            root,
            digest,
            provenance,
            stores: None,
        };
        daemon.stores = Some(daemon.compose());
        daemon
    }

    /// A daemon over the root another process left at the fixed root, not
    /// rebuilt and with no owner open yet: what a run that died there left,
    /// before any start reads it.
    pub fn attach(name: &str) -> Self {
        let fixture = super::fixture(name);
        let provenance = document(&fixture, "provenance.json");
        let root = PathBuf::from(debug_hap::ROOT);
        let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
        assert_eq!(provenance["hdcSHA256"], digest.as_str());
        let cases = document(&fixture, "cases.json");
        Self {
            dispatch: ProcessDispatch::new(
                VerifiedTool::open(root.join("hdc"), &digest).unwrap(),
                None,
            ),
            probe: OracleProbe::new(&provenance),
            default_root: root.join("store"),
            helper: cases
                .get("codeSignHelper")
                .map(|_| code_sign_helper(&cases, &root)),
            receive_root: provenance["receiveRoot"].as_str().map(PathBuf::from),
            fixture,
            root,
            digest,
            provenance,
            stores: None,
        }
    }

    /// Every owner opened afresh over the root, the Job owner first: its
    /// repository holds the account-fixed root, and the capability store is
    /// opened inside it.
    fn compose(&self) -> Stores {
        let jobs = JobStore::open_owner(&self.default_root).unwrap();
        Stores {
            targets: TargetStore::open(&self.root.join("targets-state")).unwrap(),
            artifacts: ArtifactReadStore::open(&self.root.join("artifacts")).unwrap(),
            capabilities: CapabilityStore::open(&self.default_root.join("capabilities")).unwrap(),
            sessions: SessionStore::open(
                &self.root.join("session-owner"),
                &self.root.join("Sessions"),
            )
            .unwrap(),
            holds: DeviceHolds::default(),
            claims: StorageClaims::default(),
            jobs,
        }
    }

    pub fn stores(&self) -> &Stores {
        self.stores.as_ref().unwrap()
    }

    /// The daemon started again over the same root, as Swift's oracle starts
    /// it: the old owners closed, new ones opened, then `recoverActiveJobs`.
    pub fn restart(&mut self) -> RecoveredJobs {
        drop(self.stores.take());
        let stores = self.compose();
        let recovered =
            recover_active_jobs(&stores.jobs, Some(&stores.capabilities), fixed_now).unwrap();
        self.stores = Some(stores);
        recovered
    }

    /// The daemon's owners closed, as before reading what they left.
    pub fn close(&mut self) {
        drop(self.stores.take());
    }

    /// The fake answers the next run in `mode`.
    pub fn mode(&self, mode: &str) {
        fs::write(self.root.join("hdc-mode"), format!("{mode}\n")).unwrap();
    }

    /// Every call the fake has received so far.
    pub fn calls(&self) -> String {
        fs::read_to_string(self.root.join("hdc-invocations.log")).unwrap()
    }

    /// The daemon's dispatch as the oracle's engine dispatched: every child at
    /// the fixed duration the provenance names, if it names one.
    pub fn timed(&self) -> Timed<'_> {
        Timed {
            inner: &self.dispatch,
            seconds: self.provenance["invocationSeconds"].as_f64(),
        }
    }

    /// The HDC composition this daemon's owners run and reconcile through,
    /// dispatching through `dispatch`, with the oracle's host receive root
    /// and code-sign helper.
    fn hdc<'a>(&'a self, dispatch: &'a (dyn HdcDispatch + Sync)) -> HdcComposition<'a> {
        HdcComposition {
            targets: &self.stores().targets,
            dispatch,
            receive_root: self.receive_root.as_deref(),
            tool_sha256: &self.digest,
            now: fixed_now,
            code_sign_helper: self.helper.as_ref(),
        }
    }

    fn authority(&self) -> MutationAuthority<'_> {
        let stores = self.stores();
        MutationAuthority {
            default_root: &self.default_root,
            sessions: Some(&stores.sessions),
            capabilities: &stores.capabilities,
            holds: &stores.holds,
        }
    }

    fn publisher(&self) -> SessionPublisher<'_> {
        let stores = self.stores();
        SessionPublisher {
            sessions: &stores.sessions,
            claims: &stores.claims,
            probe: &self.probe,
        }
    }

    /// `job.run` of the Job `params` names, with the mutation owner, through
    /// `dispatch`, a canceller reaching the run through `cancellation`.
    pub fn run(
        &self,
        dispatch: &(dyn HdcDispatch + Sync),
        params: &Map<String, Value>,
        cancellation: Option<&RunCancellation>,
    ) -> Value {
        self.run_on(dispatch, params, cancellation, fixed_now)
    }

    /// [`Daemon::run`] with the runner reading the clock `now`.
    pub fn run_on(
        &self,
        dispatch: &(dyn HdcDispatch + Sync),
        params: &Map<String, Value>,
        cancellation: Option<&RunCancellation>,
        now: fn() -> Option<String>,
    ) -> Value {
        let hdc = self.hdc(dispatch);
        let publisher = self.publisher();
        let runner = self.runner(&hdc, &publisher, cancellation, now);
        answer(runner.handle(params).map_err(|refusal| WireError {
            code: refusal.code.into(),
            message: refusal.message,
            details: Some(refusal.details),
        }))
    }

    /// The runner a run, a reconcile's failure finalization and a cleanup
    /// debt's continuation go through, with the mutation owner.
    fn runner<'a>(
        &'a self,
        hdc: &'a HdcComposition<'a>,
        publisher: &'a SessionPublisher<'a>,
        cancellation: Option<&'a RunCancellation>,
        now: fn() -> Option<String>,
    ) -> JobRunner<'a> {
        let stores = self.stores();
        JobRunner {
            imports: None,
            mutation: Some(MutationExecution {
                authority: self.authority(),
                state_root: &self.root,
            }),
            jobs: &stores.jobs,
            artifacts: &stores.artifacts,
            analyzer: None,
            quota: self.provenance["quotaBytes"].as_u64().unwrap(),
            home: self.provenance["home"].as_str().unwrap(),
            now,
            precise_now: fixed_precise_now,
            sessions: Some(publisher),
            cancellation,
            after_commit: None,
            hdc: Some(hdc),
        }
    }

    /// `job.reconcile` of the Job `params` names, through an HDC composition
    /// dispatching through `dispatch` (and a runner over it for a debug HAP's
    /// failure finalization), or with none.
    pub fn reconcile(
        &self,
        dispatch: Option<&(dyn HdcDispatch + Sync)>,
        params: &Map<String, Value>,
    ) -> Value {
        let stores = self.stores();
        let hdc = dispatch.map(|dispatch| self.hdc(dispatch));
        let publisher = self.publisher();
        let runner = hdc
            .as_ref()
            .map(|hdc| self.runner(hdc, &publisher, None, fixed_now));
        answer(
            JobReconciler {
                jobs: &stores.jobs,
                artifacts: &stores.artifacts,
                imports: None,
                now: fixed_now,
                sessions: Some(&publisher),
                hdc: hdc.as_ref(),
                capabilities: Some(&stores.capabilities),
                runner: runner.as_ref(),
            }
            .handle(params),
        )
    }

    /// `cleanupDebt.continue` of the debt `params` names, through the runner
    /// over an HDC composition dispatching through `dispatch`.
    pub fn continue_debt(
        &self,
        dispatch: &(dyn HdcDispatch + Sync),
        params: &Map<String, Value>,
    ) -> Value {
        let hdc = self.hdc(dispatch);
        let publisher = self.publisher();
        answer(
            self.runner(&hdc, &publisher, None, fixed_now)
                .continue_cleanup_debt(params),
        )
    }

    /// One recorded request answered by the Rust owner that serves it, with
    /// the HDC composition dispatching through `dispatch`: a submission, a
    /// run in the fake's recorded mode (then `normal` again, as the oracles
    /// set it), a reconcile, a Job read or a capability read.
    pub fn answer(&self, dispatch: &(dyn HdcDispatch + Sync), exchange: &Value) -> Value {
        let stores = self.stores();
        let method = exchange["method"].as_str().unwrap();
        let params = exchange["params"].as_object().unwrap();
        match method {
            "job.submit" => {
                let hdc = self.hdc(dispatch);
                let admitter = JobAdmitter {
                    planner: JobPlanner {
                        imports: None,
                        artifacts: Some(&stores.artifacts),
                        analyzer: None,
                        state_root: &self.root,
                        hdc: Some(&hdc),
                    },
                    jobs: &stores.jobs,
                    now: fixed_now,
                    authority: Some(self.authority()),
                };
                answer(admitter.handle(params).map_err(|refusal| WireError {
                    code: refusal.code.into(),
                    message: refusal.message,
                    details: Some(if refusal.proven { proven() } else { Map::new() }),
                }))
            }
            "job.run" => {
                if let Some(mode) = exchange["mode"].as_str() {
                    self.mode(mode);
                }
                let ran = self.run(dispatch, params, None);
                self.mode("normal");
                ran
            }
            "job.reconcile" => self.reconcile(Some(dispatch), params),
            "job.status" | "job.show" => answer(stores.jobs.handle_resource(method, params)),
            "job.result" | "job.evidence" => answer(
                JobResultReader {
                    jobs: &stores.jobs,
                    artifacts: &stores.artifacts,
                }
                .handle(method, params),
            ),
            "cleanupDebt.list" => {
                answer(
                    list_cleanup_debt(&stores.artifacts).map_err(|message| WireError {
                        code: "internalError".into(),
                        message,
                        details: None,
                    }),
                )
            }
            "cleanupDebt.continue" => self.continue_debt(dispatch, params),
            "capability.list" | "capability.inspect" => answer(
                stores
                    .capabilities
                    .handle(method, params)
                    .map_err(|refusal| WireError {
                        code: refusal.code.into(),
                        message: refusal.message,
                        details: None,
                    }),
            ),
            other => panic!("{}: the oracle sent {other}", exchange["name"]),
        }
    }

    /// The store snapshot the oracle recorded under `prefix`: the Job index
    /// and every Job file (records read machine-independently) and every file
    /// of the capability store, byte for byte, and, where the oracle kept it,
    /// the calls the fake had received.
    pub fn assert_snapshot(&self, prefix: &str) {
        assert_store(&self.fixture, prefix, &self.default_root);
        let files = |base: &Path| -> BTreeMap<String, Vec<u8>> {
            let mut files = BTreeMap::new();
            for entry in fs::read_dir(base).into_iter().flatten() {
                let path = entry.unwrap().path();
                files.insert(
                    path.file_name().unwrap().to_str().unwrap().to_owned(),
                    fs::read(&path).unwrap(),
                );
            }
            files
        };
        let recorded = files(&self.fixture.join(prefix).join("capabilities"));
        let actual = files(&self.default_root.join("capabilities"));
        assert_eq!(
            actual.keys().collect::<Vec<_>>(),
            recorded.keys().collect::<Vec<_>>(),
            "{prefix}/capabilities"
        );
        for (name, bytes) in &recorded {
            assert_eq!(
                String::from_utf8_lossy(&actual[name]),
                String::from_utf8_lossy(bytes),
                "{prefix}/capabilities/{name}"
            );
        }
        let calls = self.fixture.join(prefix).join("hdc-invocations.log");
        if calls.exists() {
            assert_eq!(
                self.calls(),
                fs::read_to_string(calls).unwrap(),
                "{prefix}/hdc-invocations.log"
            );
        }
    }

    /// What the replay leaves below the root against what the oracle
    /// recorded: the fake's every call, the Target document, and the Job
    /// store, capability store, Sessions, storage owner, Artifacts and tree
    /// byte for byte. The owners are closed first.
    pub fn assert_leftovers(&mut self) {
        self.close();
        assert_eq!(
            self.calls(),
            fs::read_to_string(self.fixture.join("hdc-invocations.log")).unwrap(),
            "the fake's calls"
        );
        assert_eq!(
            fs::read(self.root.join("targets-state/targets.json")).unwrap(),
            fs::read(self.fixture.join("targets-state/targets.json")).unwrap(),
            "the Target document"
        );
        super::assert_leftovers_at(&self.fixture, &self.root, &self.default_root);
    }
}
