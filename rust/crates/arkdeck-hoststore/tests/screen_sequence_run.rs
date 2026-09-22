//! Replays the Swift screen-sequence oracle (`rust/tests/fixtures/screen-sequence`,
//! recorded by `ScreenSequenceOracleContractTests` over the shared fake HDC)
//! through the production Rust planner, admitter, runner, result reader and
//! capability reads, under the durable mutation authority the pointer, port
//! and HAP replays run under: the account-fixed Job root, each Job's one
//! capability use consumed after its storage preflight and before its capture's
//! intent and continued by its cleanup, and the use settled once the Job is
//! terminal or parked. The composition names the oracle's host receive root,
//! and its dispatcher reports every child at the oracle's fixed duration, as
//! Swift's `FixedDurationDispatcher` did. Every exchange answers as Swift
//! answered it, message included:
//! - three captures (JPEG by default, a scaled PNG run, and one whose second
//!   still fails, which is a gap and not a failure) each receive their
//!   archive, publish it as `frames.tar` from the landed file, remove the
//!   landing copy, clean the device up and publish `sequence.json`;
//! - storage the device lacks fails a Job before its capability use is
//!   consumed;
//! - an empty archive fails at the capture and a cleanup that leaves the frame
//!   directory fails after `frames.tar` is published, neither with a debt or
//!   a compensation, as Swift's, so `cleanupDebt.list` lists nothing;
//! - an archive the readback cannot find parks its Job with its intent
//!   outstanding, and its unknown use refuses `afterUnknown`;
//! - a lone scaled dimension and a single frame are refused at planning.
//!
//! The fake receives Swift's 84 calls in order, and everything the replay
//! leaves below the root is Swift's byte for byte. Two more tests take what no
//! oracle records: a composition that names no host receive root plans no
//! sequence, and another root plans another digest. Every transport byte comes
//! from the shared fake HDC; none of this is hardware acceptance. The runs
//! spawn the fake, so this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, HdcComposition, JobAdmitter, JobPlanner,
    JobResultReader, JobRunner, JobStore, MutationAuthority, MutationExecution, SessionPublisher,
    SessionStore, StorageClaims, TargetStore, list_cleanup_debt,
};
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;
use support::debug_hap;
use support::{OracleProbe, fixed_now, fixed_precise_now};

/// Every call Swift's runs made.
const CALLS: usize = 84;

fn refused(code: &str, message: String, details: Option<Map<String, Value>>) -> Value {
    let mut error = json!({"code": code, "message": message});
    if let Some(details) = details {
        error["details"] = Value::Object(details);
    }
    json!({"ok": false, "error": error})
}

fn proven() -> Map<String, Value> {
    Map::from_iter([
        ("phase".into(), json!("preAdmission")),
        ("newDispatchCount".into(), json!(0)),
    ])
}

fn exchange<'a>(cases: &'a Value, name: &str) -> &'a Value {
    cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == name)
        .unwrap()
}

/// Swift's `FixedDurationDispatcher` over the process dispatch: every child
/// reported at the oracle's duration, everything else forwarded unchanged.
struct FixedDuration<'a> {
    inner: &'a ProcessDispatch,
    duration: Duration,
}

impl HdcDispatch for FixedDuration<'_> {
    fn mutation_identity_current(&self) -> bool {
        self.inner.mutation_identity_current()
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let mut receipt = self.inner.dispatch(plan)?;
        receipt.duration = self.duration;
        Ok(receipt)
    }
}

/// The owners a daemon composes over the rebuilt root, the Job owner's root
/// the account-fixed one its mutation authority names.
struct Owners {
    root: PathBuf,
    default_root: PathBuf,
    receive_root: PathBuf,
    digest: String,
    provenance: Value,
    targets: TargetStore,
    artifacts: ArtifactReadStore,
    jobs: JobStore,
    capabilities: CapabilityStore,
    sessions: SessionStore,
    dispatch: ProcessDispatch,
    holds: DeviceHolds,
    claims: StorageClaims,
    probe: OracleProbe,
}

impl Owners {
    /// The owners over the root rebuilt from `fixture`; the caller holds
    /// [`debug_hap::exclusive`].
    fn open(fixture: &Path) -> Self {
        let provenance = support::document(fixture, "provenance.json");
        let root = debug_hap::rebuild(fixture);
        assert_eq!(provenance["root"], root.to_str().unwrap());
        let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
        assert_eq!(provenance["hdcSHA256"], digest.as_str());
        let default_root = root.join("store");
        let jobs = JobStore::open_owner(&default_root).unwrap();
        let capabilities = CapabilityStore::open(&default_root.join("capabilities")).unwrap();
        Self {
            receive_root: PathBuf::from(provenance["receiveRoot"].as_str().unwrap()),
            targets: TargetStore::open(&root.join("targets-state")).unwrap(),
            artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
            jobs,
            capabilities,
            sessions: SessionStore::open(&root.join("session-owner"), &root.join("Sessions"))
                .unwrap(),
            dispatch: ProcessDispatch::new(
                VerifiedTool::open(root.join("hdc"), &digest).unwrap(),
                None,
            ),
            holds: DeviceHolds::default(),
            claims: StorageClaims::default(),
            probe: OracleProbe::new(&provenance),
            provenance,
            digest,
            default_root,
            root,
        }
    }

    /// The dispatch the oracle recorded through: its fixed child duration.
    fn fixed(&self) -> FixedDuration<'_> {
        FixedDuration {
            inner: &self.dispatch,
            duration: Duration::from_secs_f64(
                self.provenance["invocationSeconds"].as_f64().unwrap(),
            ),
        }
    }

    fn hdc<'a>(
        &'a self,
        dispatch: &'a (dyn HdcDispatch + Sync),
        receive_root: Option<&'a Path>,
    ) -> HdcComposition<'a> {
        HdcComposition {
            targets: &self.targets,
            dispatch,
            receive_root,
            tool_sha256: &self.digest,
            now: fixed_now,
            code_sign_helper: None,
        }
    }

    fn authority(&self) -> MutationAuthority<'_> {
        MutationAuthority {
            default_root: &self.default_root,
            sessions: Some(&self.sessions),
            capabilities: &self.capabilities,
            holds: &self.holds,
        }
    }

    fn planner<'a>(&'a self, hdc: &'a HdcComposition<'a>) -> JobPlanner<'a> {
        JobPlanner {
            imports: None,
            artifacts: Some(&self.artifacts),
            analyzer: None,
            state_root: &self.root,
            hdc: Some(hdc),
        }
    }

    fn admitter<'a>(&'a self, hdc: &'a HdcComposition<'a>) -> JobAdmitter<'a> {
        JobAdmitter {
            planner: self.planner(hdc),
            jobs: &self.jobs,
            now: fixed_now,
            authority: Some(self.authority()),
        }
    }

    fn publisher(&self) -> SessionPublisher<'_> {
        SessionPublisher {
            sessions: &self.sessions,
            claims: &self.claims,
            probe: &self.probe,
        }
    }

    fn runner<'a>(
        &'a self,
        hdc: &'a HdcComposition<'a>,
        publisher: &'a SessionPublisher<'a>,
    ) -> JobRunner<'a> {
        JobRunner {
            imports: None,
            mutation: Some(MutationExecution {
                authority: self.authority(),
                state_root: &self.root,
            }),
            jobs: &self.jobs,
            artifacts: &self.artifacts,
            analyzer: None,
            quota: self.provenance["quotaBytes"].as_u64().unwrap(),
            home: self.provenance["home"].as_str().unwrap(),
            now: fixed_now,
            precise_now: fixed_precise_now,
            sessions: Some(publisher),
            cancellation: None,
            after_commit: None,
            hdc: Some(hdc),
        }
    }

    fn record(&self, job: &str) -> Value {
        let path = self
            .default_root
            .join("jobs")
            .join(job)
            .join("job-record.json");
        serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
    }

    fn calls(&self) -> String {
        fs::read_to_string(self.root.join("hdc-invocations.log")).unwrap()
    }

    fn mode(&self, mode: &str) {
        fs::write(self.root.join("hdc-mode"), format!("{mode}\n")).unwrap();
    }
}

/// Every recorded request but the cleanup debt list, answered in order by the
/// Rust owners. Every answer must be Swift's, its message included, and so
/// must each call the fake received, the Target document and everything the
/// replay leaves below the root; the receive root is left empty.
#[test]
fn rust_captures_every_swift_screen_sequence_as_swift_does() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("screen-sequence");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let dispatch = owners.fixed();
    let hdc = owners.hdc(&dispatch, Some(&owners.receive_root));
    let admitter = owners.admitter(&hdc);
    let publisher = owners.publisher();
    let runner = owners.runner(&hdc, &publisher);
    let reader = JobResultReader {
        jobs: &owners.jobs,
        artifacts: &owners.artifacts,
    };
    let (mut differences, mut replayed) = (Vec::new(), 0);
    for exchange in cases["exchanges"].as_array().unwrap() {
        let (name, method) = (&exchange["name"], exchange["method"].as_str().unwrap());
        replayed += 1;
        let params = exchange["params"].as_object().unwrap();
        let actual = match method {
            "job.plan" => match owners.planner(&hdc).handle(params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(refusal.code, refusal.message, Some(proven())),
            },
            "job.submit" => match admitter.handle(params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(
                    refusal.code,
                    refusal.message,
                    Some(if refusal.proven { proven() } else { Map::new() }),
                ),
            },
            "job.run" => {
                if let Some(mode) = exchange["mode"].as_str() {
                    owners.mode(mode);
                }
                match runner.handle(params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(refusal) => refused(refusal.code, refusal.message, Some(refusal.details)),
                }
            }
            "job.result" | "job.evidence" => match reader.handle(method, params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(error) => refused(&error.code, error.message, error.details),
            },
            "artifact.list" => {
                let jobs = &owners.jobs;
                match owners
                    .artifacts
                    .handle_list(params, &jobs.snapshot_directory(), |job| {
                        jobs.read_snapshot(job).map(|_| ())
                    }) {
                    // The pager's revision is its own; the oracle labels it.
                    Ok(mut result) => {
                        result["snapshotRevision"] = json!("<snapshotRevision>");
                        json!({"ok": true, "result": result})
                    }
                    Err(error) => refused(&error.code, error.message, error.details),
                }
            }
            "capability.list" | "capability.inspect" => {
                match owners.capabilities.handle(method, params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(error) => refused(error.code, error.message, None),
                }
            }
            "cleanupDebt.list" => match list_cleanup_debt(&owners.artifacts) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(message) => refused("internalError", message, None),
            },
            other => panic!("{name}: the oracle sent {other}"),
        };
        let actual = support::legacy_plan_answer(actual);
        if actual != exchange["answer"] {
            differences.push(format!(
                "{name}:\n  swift {}\n  rust  {actual}",
                exchange["answer"]
            ));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    assert!(replayed >= 51, "{replayed} exchanges replayed");

    // The fake received Swift's calls, in order.
    let swift = fs::read_to_string(fixture.join("hdc-invocations.log")).unwrap();
    assert_eq!(swift.lines().count(), CALLS);
    assert_eq!(owners.calls(), swift, "the fake's calls");
    assert_eq!(
        fs::read(owners.root.join("targets-state/targets.json")).unwrap(),
        fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        "the Target document"
    );
    // Nothing is owed, and no landing copy outlives its publication.
    assert!(!owners.root.join("artifacts/cleanup-debt.json").exists());
    let landed: Vec<_> = fs::read_dir(&owners.receive_root)
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert!(landed.is_empty(), "{landed:?}");

    // A Job consumed its one use after its storage preflight, before its
    // capture; one the device's storage refused consumed none.
    for (case, job) in cases["jobs"].as_object().unwrap() {
        let timeline = owners.record(job.as_str().unwrap())["timeline"].clone();
        let consumed = timeline
            .as_array()
            .unwrap()
            .iter()
            .filter(|line| *line == "capability consumed before first mutation")
            .count();
        assert_eq!(consumed, usize::from(case != "lowStorage"), "{case}");
    }

    // The parked Job stays parked: recovery (design §L.1 item 13) is not
    // this runner's, and running it again is refused before anything is
    // dispatched.
    let parked = cases["jobs"]["missingArchive"].as_str().unwrap();
    let refusal = runner
        .handle(&Map::from_iter([("jobId".into(), json!(parked))]))
        .unwrap_err();
    assert_eq!(
        (refusal.code, refusal.message),
        (
            "resourceConflict",
            format!("job {parked} is waitingForRecovery, not runnable")
        )
    );
    assert_eq!(owners.calls(), swift, "nothing more was dispatched");

    let Owners {
        jobs,
        root,
        default_root,
        ..
    } = owners;
    drop(jobs);
    support::assert_leftovers_at(&fixture, &root, &default_root);
}

/// A composition that names no host receive root cannot say where the
/// archive would land, so it plans no screen sequence and dispatches nothing;
/// one that names another root plans another digest, since the receive argv
/// names the landing path (the S0 record's third maintainer question).
#[test]
fn the_host_receive_root_is_part_of_the_plan() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("screen-sequence");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let params = exchange(&cases, "captured.plan")["params"]
        .as_object()
        .unwrap()
        .clone();
    let dispatch = owners.fixed();
    let unrooted = owners.hdc(&dispatch, None);
    let refusal = owners.planner(&unrooted).handle(&params).unwrap_err();
    assert_eq!(
        (refusal.code, refusal.message.as_str()),
        (
            "rejected",
            "capture.screen-sequence@1 is not materialized by the Rust Runtime without a host \
             receive root"
        )
    );
    let elsewhere = owners.root.join("elsewhere");
    let rerooted = owners.hdc(&dispatch, Some(&elsewhere));
    let plan = owners.planner(&rerooted).handle(&params).unwrap();
    let recorded = &exchange(&cases, "captured.plan")["answer"]["result"];
    assert_ne!(
        plan["materializedPlanDigest"],
        recorded["materializedPlanDigest"]
    );
    let rooted = owners.hdc(&dispatch, Some(&owners.receive_root));
    let answer = json!({"ok":true,"result":owners.planner(&rooted).handle(&params).unwrap()});
    assert_eq!(support::legacy_plan_answer(answer)["result"], *recorded);
    assert_eq!(owners.calls(), "", "planning dispatches nothing");
    assert!(!elsewhere.exists(), "planning prepares no landing");
}
