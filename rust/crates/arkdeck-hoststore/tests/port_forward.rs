//! Replays the Swift port-forward oracle (`rust/tests/fixtures/port-forward`,
//! recorded by `PortForwardOracleContractTests`) through the production Rust
//! planner, admitter, runner, result reader and capability reads over the
//! shared fake HDC, with the durable mutation authority the pointer replay
//! runs under (`pointer_input_run.rs`): the account-fixed Job root, the Job's
//! capability use consumed before its change's intent, and the use settled
//! once the Job is terminal or parked.
//! - Each run consumes one use of the capability its submission was issued
//!   (one per exact rule), changes the rule, reads it back and publishes the
//!   readback.
//! - A refused change, or the removal of a rule the device does not hold,
//!   fails the Job with nothing to undo.
//! - A created rule the readback does not find is removed again and read back
//!   absent before the Job fails.
//! - A readback the device does not answer parks the Job, and its unknown use
//!   refuses `afterUnknown`.
//!
//! The oracle's compensation succeeds. Two more tests take its failures,
//! which no oracle records: a refused removal, and a dispatcher that can no
//! longer prove its executable. Another holds a port rule to the mutation
//! authority: another root's owner admits none, and a runner without the
//! mutation owner changes none. Every transport byte comes from the shared
//! fake HDC; none of this is hardware acceptance. The runs spawn the fake, so
//! this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, HdcComposition, JobAdmitter, JobPlanner,
    JobResultReader, JobRunner, JobStore, MutationAuthority, MutationExecution, SessionPublisher,
    SessionStore, StorageClaims, TargetStore,
};
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use support::{OracleProbe, chmod, fixed_now, fixed_precise_now};

/// `HDCOracleFake`'s fixed root and lock, which the fake's driver names.
const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";

/// Serializes every user of the fixed root, Swift producers included.
fn exclusive() -> File {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(LOCK)
        .unwrap();
    lock.lock().unwrap();
    lock
}

/// The root as `HDCOracleFake.install` left it, with the Target document the
/// Swift oracle's adoption wrote; the Job owner's root is `store`.
fn rebuild(fixture: &Path) -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    for directory in [
        root.clone(),
        root.join("targets-state"),
        root.join("artifacts"),
        root.join("store"),
        root.join("Sessions"),
        root.join("session-owner"),
    ] {
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
    }
    fs::copy(fixture.join("hdc"), root.join("hdc")).unwrap();
    chmod(&root.join("hdc"), 0o700);
    fs::copy(fixture.join("hdc-answers.sh"), root.join("hdc-answers.sh")).unwrap();
    fs::write(root.join("hdc-invocations.log"), b"").unwrap();
    fs::copy(
        fixture.join("targets-state/targets.json"),
        root.join("targets-state/targets.json"),
    )
    .unwrap();
    // Owner-only, as the Target owner requires and Swift wrote it; a checkout
    // leaves the fixture group-readable.
    chmod(&root.join("targets-state/targets.json"), 0o600);
    root
}

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

/// The owners a daemon composes over the rebuilt root. The Job owner's root
/// is the account-fixed one its mutation authority names, and the capability
/// store is opened inside it once the Job owner holds it, as the daemon opens
/// it (a new Job repository takes only an empty directory).
struct Owners {
    root: PathBuf,
    default_root: PathBuf,
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
    /// [`exclusive`].
    fn open(fixture: &Path) -> Self {
        let provenance = support::document(fixture, "provenance.json");
        let root = rebuild(fixture);
        let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
        assert_eq!(provenance["hdcSHA256"], digest.as_str());
        let default_root = root.join("store");
        let jobs = JobStore::open_owner(&default_root).unwrap();
        let capabilities = CapabilityStore::open(&default_root.join("capabilities")).unwrap();
        Self {
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

    fn hdc<'a>(&'a self, dispatch: &'a (dyn HdcDispatch + Sync)) -> HdcComposition<'a> {
        HdcComposition {
            targets: &self.targets,
            dispatch,
            receive_root: None,
            tool_sha256: &self.digest,
            now: fixed_now,
            code_sign_helper: None,
        }
    }

    /// The mutation authority of the owner whose account-fixed Job root is
    /// `default_root`.
    fn authority<'a>(&'a self, default_root: &'a Path) -> MutationAuthority<'a> {
        MutationAuthority {
            default_root,
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
            workspace: None,
        }
    }

    fn admitter<'a>(
        &'a self,
        hdc: &'a HdcComposition<'a>,
        default_root: &'a Path,
    ) -> JobAdmitter<'a> {
        JobAdmitter {
            planner: self.planner(hdc),
            jobs: &self.jobs,
            now: fixed_now,
            authority: Some(self.authority(default_root)),
        }
    }

    fn publisher(&self) -> SessionPublisher<'_> {
        SessionPublisher {
            sessions: &self.sessions,
            claims: &self.claims,
            probe: &self.probe,
        }
    }

    /// The runner, with or without the mutation owner a device mutation
    /// consumes its use through.
    fn runner<'a>(
        &'a self,
        hdc: &'a HdcComposition<'a>,
        publisher: &'a SessionPublisher<'a>,
        owned: bool,
    ) -> JobRunner<'a> {
        JobRunner {
            imports: None,
            mutation: owned.then(|| MutationExecution {
                authority: self.authority(&self.default_root),
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
            workspace: None,
        }
    }

    fn record(&self, job: &str) -> Value {
        serde_json::from_slice(
            &fs::read(
                self.default_root
                    .join("jobs")
                    .join(job)
                    .join("job-record.json"),
            )
            .unwrap(),
        )
        .unwrap()
    }
}

/// Every recorded request, answered in order by the Rust owners. Every answer
/// must be Swift's, its message included, and so must each call the fake
/// received, the Target document and everything the replay leaves below the
/// root.
#[test]
fn rust_changes_the_swift_port_rules_under_the_capabilities_swift_consumed() {
    let _lock = exclusive();
    let fixture = support::fixture("port-forward");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc(&owners.dispatch);
    let admitter = owners.admitter(&hdc, &owners.default_root);
    let publisher = owners.publisher();
    let runner = owners.runner(&hdc, &publisher, true);
    let reader = JobResultReader {
        jobs: &owners.jobs,
        artifacts: &owners.artifacts,
    };
    let mut differences = Vec::new();
    for exchange in cases["exchanges"].as_array().unwrap() {
        let (name, method) = (&exchange["name"], exchange["method"].as_str().unwrap());
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
                    fs::write(owners.root.join("hdc-mode"), format!("{mode}\n")).unwrap();
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
                    .handle_list(params, |job| jobs.read_snapshot(job).map(|_| ()))
                {
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
    assert_eq!(
        String::from_utf8(fs::read(owners.root.join("hdc-invocations.log")).unwrap()).unwrap(),
        String::from_utf8(fs::read(fixture.join("hdc-invocations.log")).unwrap()).unwrap(),
        "the fake's calls"
    );
    assert_eq!(
        fs::read(owners.root.join("targets-state/targets.json")).unwrap(),
        fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        "the Target document"
    );
    let Owners {
        jobs,
        root,
        default_root,
        ..
    } = owners;
    drop(jobs);
    support::assert_leftovers_at(&fixture, &root, &default_root);
}

/// What goes wrong once the rule's readback has been dispatched.
#[derive(Clone, Copy, PartialEq)]
enum Fault {
    /// The device refuses every rule removal, as it refuses to remove a rule
    /// it does not hold.
    RefusedRemoval,
    /// The dispatcher can no longer prove the executable it retained.
    UnprovenTool,
}

/// The fake as the oracle drives it, but for `fault` once `fport ls` has
/// been dispatched.
struct AfterReadback<'a> {
    inner: &'a ProcessDispatch,
    fault: Fault,
    read: AtomicBool,
}

impl HdcDispatch for AfterReadback<'_> {
    fn mutation_identity_current(&self) -> bool {
        !(self.fault == Fault::UnprovenTool && self.read.load(Ordering::SeqCst))
            && self.inner.mutation_identity_current()
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let names = |command: [&str; 2]| plan.arguments.windows(2).any(|pair| pair == command);
        if names(["fport", "ls"]) {
            self.read.store(true, Ordering::SeqCst);
        }
        if self.fault == Fault::RefusedRemoval && names(["fport", "rm"]) {
            return Ok(Receipt {
                exit_status: 1,
                stdout: b"[Fail]Remove forward ruler failed, ruler is not exist\n".to_vec(),
                stderr: Vec::new(),
                truncated: false,
                duration: Duration::ZERO,
            });
        }
        self.inner.dispatch(plan)
    }
}

/// How many of the fake's calls carry `arguments` in a row. The fake logs a
/// call as its arguments, each ended by a unit separator, one call a line.
fn calls_of(calls: &str, arguments: &[&str]) -> usize {
    let run: String = arguments
        .iter()
        .map(|argument| format!("{argument}\u{1f}"))
        .collect();
    calls.lines().filter(|line| line.contains(&run)).count()
}

/// What `ruleUnlisted`'s run left: the Job's timeline from the readback's
/// failure on, its record and journal, and the calls the fake received.
struct Unlisted {
    tail: Vec<String>,
    record: Value,
    journal: String,
    calls: String,
}

/// `ruleUnlisted`'s submission and run with `fault`. The Job must fail, and
/// its use must be settled all the same.
fn unlisted_rule_with(fault: Fault) -> Unlisted {
    let _lock = exclusive();
    let fixture = support::fixture("port-forward");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let dispatch = AfterReadback {
        inner: &owners.dispatch,
        fault,
        read: AtomicBool::new(false),
    };
    let hdc = owners.hdc(&dispatch);
    let publisher = owners.publisher();
    let submit = exchange(&cases, "ruleUnlisted.submit");
    owners
        .admitter(&hdc, &owners.default_root)
        .handle(submit["params"].as_object().unwrap())
        .unwrap();
    fs::write(owners.root.join("hdc-mode"), "ruleUnlisted\n").unwrap();
    let job = cases["jobs"]["ruleUnlisted"].as_str().unwrap();
    let status = owners
        .runner(&hdc, &publisher, true)
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap();
    assert_eq!(status["state"], "failed");
    let record = owners.record(job);
    let timeline: Vec<String> = record["timeline"]
        .as_array()
        .unwrap()
        .iter()
        .map(|line| line.as_str().unwrap().to_owned())
        .collect();
    let readback = timeline
        .iter()
        .position(|line| line.starts_with("failed verify-port-rule:"))
        .unwrap();
    let capability = record["admissionEvidence"]["reference"].as_str().unwrap();
    let inspected = owners
        .capabilities
        .handle(
            "capability.inspect",
            &Map::from_iter([("capabilityId".into(), json!(capability))]),
        )
        .unwrap();
    let settled = &inspected["lineage"][0]["outcomeHistory"][0];
    assert_eq!(
        (&settled["outcome"], &settled["terminalState"]),
        (&json!("confirmed"), &json!("failed")),
    );
    Unlisted {
        tail: timeline[readback..].to_vec(),
        journal: fs::read_to_string(
            owners
                .default_root
                .join("jobs")
                .join(job)
                .join("journal.jsonl"),
        )
        .unwrap(),
        calls: fs::read_to_string(owners.root.join("hdc-invocations.log")).unwrap(),
        record,
    }
}

/// When the removal that should restore an unlisted rule is refused too, the
/// Job fails with the compensation's failure rather than the readback's,
/// after the timeline says the compensation failed closed.
#[test]
fn a_compensation_that_fails_fails_the_job_closed() {
    let Unlisted { tail, calls, .. } = unlisted_rule_with(Fault::RefusedRemoval);
    assert_eq!(
        tail,
        [
            "failed verify-port-rule: portForwardReadbackMismatch: the exact typed rule is absent after create",
            "intent compensate-port-rule",
            "failed compensate-port-rule: portForwardFailed: tcp:23455",
            "port-rule compensation failed closed: failed(\"portForwardFailed: tcp:23455\")",
            "running->finalizing",
            "reason: portForwardFailed: tcp:23455",
            "finalizing->failed",
            "reason: portForwardFailed: tcp:23455",
        ]
    );
    // The fake created the rule and read it back once each; the refused
    // removal never reached it, and nothing was read back after it.
    assert_eq!(
        (
            calls_of(&calls, &["fport", "tcp:23455", "tcp:34565"]),
            calls_of(&calls, &["fport", "ls"]),
            calls_of(&calls, &["fport", "rm"]),
        ),
        (1, 1, 0),
        "{calls}"
    );
}

/// The compensation's change is a device mutation too: a dispatcher that can
/// no longer prove its executable dispatches none, and the Job fails with
/// that refusal before any compensating intent exists.
#[test]
fn a_compensation_never_changes_a_rule_through_an_unproven_tool() {
    let Unlisted {
        tail,
        record,
        journal,
        calls,
    } = unlisted_rule_with(Fault::UnprovenTool);
    let refusal = "authorizationRequired: fresh tool identity cannot be proved";
    assert_eq!(
        tail,
        [
            "failed verify-port-rule: portForwardReadbackMismatch: the exact typed rule is absent after create".to_owned(),
            format!("port-rule compensation failed closed: failed(\"{refusal}\")"),
            "running->finalizing".to_owned(),
            format!("reason: {refusal}"),
            "finalizing->failed".to_owned(),
            format!("reason: {refusal}"),
        ]
    );
    assert_eq!(calls_of(&calls, &["fport", "rm"]), 0, "{calls}");
    assert!(record["recoveryStepID"].is_null(), "{record}");
    assert!(!journal.contains("compensate-port-rule"), "{journal}");
}

/// A port rule changes only under the mutation authority: an owner whose
/// account-fixed Job root is elsewhere admits no rule and issues nothing,
/// and a runner without the mutation owner fails the admitted Job before its
/// change, consuming nothing and dispatching no `fport`.
#[test]
fn no_port_rule_changes_without_the_mutation_authority() {
    let _lock = exclusive();
    let fixture = support::fixture("port-forward");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc(&owners.dispatch);
    let publisher = owners.publisher();
    let submit = exchange(&cases, "createForward.submit")["params"]
        .as_object()
        .unwrap();
    let elsewhere = owners.root.join("elsewhere");
    let refusal = owners
        .admitter(&hdc, &elsewhere)
        .handle(submit)
        .unwrap_err();
    assert_eq!(
        (refusal.code, refusal.proven),
        ("admissionDenied", true),
        "{}",
        refusal.message
    );
    let store = owners.default_root.join("capabilities");
    assert!(!store.join("runtime-capabilities.json").exists());
    owners
        .admitter(&hdc, &owners.default_root)
        .handle(submit)
        .unwrap();
    fs::write(owners.root.join("hdc-mode"), "normal\n").unwrap();
    let job = cases["jobs"]["createForward"].as_str().unwrap();
    let status = owners
        .runner(&hdc, &publisher, false)
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap();
    assert_eq!(status["state"], "failed");
    let record = owners.record(job);
    assert!(record["admissionEvidence"].is_null(), "{record}");
    assert!(
        record["timeline"].as_array().unwrap().contains(&json!(
            "reason: authorizationRequired: Runtime mutation owner is unavailable"
        )),
        "{record}"
    );
    let calls = fs::read_to_string(owners.root.join("hdc-invocations.log")).unwrap();
    assert_eq!(calls_of(&calls, &["fport"]), 0, "{calls}");
    let journal = fs::read_to_string(
        owners
            .default_root
            .join("jobs")
            .join(job)
            .join("journal.jsonl"),
    )
    .unwrap();
    assert!(!journal.contains("intent-create-port-rule"), "{journal}");
    assert!(!store.join("runtime-capabilities.ledger").exists());
}
