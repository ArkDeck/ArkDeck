//! What the replays of the Swift oracles recorded over the shared fake HDC
//! (`HDCOracleFake`, at the fixed root `support/debug_hap.rs` rebuilds) share
//! when their Jobs mutate a device under Runtime capabilities: the owners a
//! daemon composes over that root, the code-sign helper where the oracle
//! composed one, and the replay of every recorded request before the
//! oracle's cleanup debt continuations (`cleanupDebt.*`, not served by this
//! Runtime), each run while the fake answers in the mode the oracle names with
//! its application state cleared first, as each oracle clears it. What the
//! replay leaves is Swift's byte for byte, the Jobs whose debts the
//! continuations settle and the ledger as they stood before them.
use super::native_library::code_sign_helper;
use super::{OracleProbe, debug_hap, document, fixed_now, fixed_precise_now};
use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, HdcComposition, JobAdmitter, JobPlanner,
    JobResultReader, JobRunner, JobStore, MutationAuthority, MutationExecution, SessionPublisher,
    SessionStore, StorageClaims, TargetStore,
};
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::{CodeSignHelper, HdcDispatch, ProcessDispatch};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::{Path, PathBuf};

/// The fake's application state, which each oracle clears before every Job
/// it runs: whether a package is installed, whether the ability runs, and
/// whether a new native library is published.
const APPLICATION_STATE: [&str; 3] = ["device-installed", "device-running", "device-published"];
/// What a continuation adds to the ledger record it settles.
const SETTLEMENT: [&str; 2] = ["retryAttemptStartedAtUTC", "settledAtUTC"];
/// A continuation's persists of its Job: its recovery load and its residue.
const CONTINUATION_PERSISTS: i64 = 2;

pub fn refused(code: &str, message: String, details: Option<Map<String, Value>>) -> Value {
    let mut error = json!({"code": code, "message": message});
    if let Some(details) = details {
        error["details"] = Value::Object(details);
    }
    json!({"ok": false, "error": error})
}

pub fn proven() -> Map<String, Value> {
    Map::from_iter([
        ("phase".into(), json!("preAdmission")),
        ("newDispatchCount".into(), json!(0)),
    ])
}

pub fn exchange<'a>(cases: &'a Value, name: &str) -> &'a Value {
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
/// it (a new Job repository takes only an empty directory). The HDC
/// composition carries the code-sign helper the oracle composed, if any.
pub struct Owners {
    pub root: PathBuf,
    pub default_root: PathBuf,
    pub digest: String,
    pub provenance: Value,
    pub targets: TargetStore,
    pub artifacts: ArtifactReadStore,
    pub jobs: JobStore,
    pub capabilities: CapabilityStore,
    pub sessions: SessionStore,
    pub dispatch: ProcessDispatch,
    pub holds: DeviceHolds,
    pub claims: StorageClaims,
    pub probe: OracleProbe,
    pub helper: Option<CodeSignHelper>,
}

impl Owners {
    /// The owners over the root rebuilt from `fixture`; the caller holds
    /// [`debug_hap::exclusive`].
    pub fn open(fixture: &Path) -> Self {
        let provenance = document(fixture, "provenance.json");
        let cases = document(fixture, "cases.json");
        let root = debug_hap::rebuild(fixture);
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
            helper: cases
                .get("codeSignHelper")
                .map(|_| code_sign_helper(&cases, &root)),
            provenance,
            digest,
            default_root,
            root,
        }
    }

    pub fn hdc<'a>(&'a self, dispatch: &'a (dyn HdcDispatch + Sync)) -> HdcComposition<'a> {
        HdcComposition {
            targets: &self.targets,
            dispatch,
            receive_root: None,
            tool_sha256: &self.digest,
            now: fixed_now,
            code_sign_helper: self.helper.as_ref(),
        }
    }

    /// The mutation authority of the owner whose account-fixed Job root is
    /// `default_root`.
    pub fn authority<'a>(&'a self, default_root: &'a Path) -> MutationAuthority<'a> {
        MutationAuthority {
            default_root,
            sessions: Some(&self.sessions),
            capabilities: &self.capabilities,
            holds: &self.holds,
        }
    }

    pub fn planner<'a>(&'a self, hdc: &'a HdcComposition<'a>) -> JobPlanner<'a> {
        JobPlanner {
            imports: None,
            artifacts: Some(&self.artifacts),
            analyzer: None,
            state_root: &self.root,
            hdc: Some(hdc),
        }
    }

    pub fn admitter<'a>(
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

    pub fn publisher(&self) -> SessionPublisher<'_> {
        SessionPublisher {
            sessions: &self.sessions,
            claims: &self.claims,
            probe: &self.probe,
        }
    }

    /// The runner, with or without the mutation owner a device mutation
    /// consumes its use through.
    pub fn runner<'a>(
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
        }
    }

    pub fn job_file(&self, job: &str, name: &str) -> PathBuf {
        self.default_root.join("jobs").join(job).join(name)
    }

    pub fn record(&self, job: &str) -> Value {
        serde_json::from_slice(&fs::read(self.job_file(job, "job-record.json")).unwrap()).unwrap()
    }

    pub fn calls(&self) -> String {
        fs::read_to_string(self.root.join("hdc-invocations.log")).unwrap()
    }

    /// The fake answers the next Job in `mode`, its application state cleared
    /// first, as each oracle clears it before every Job it runs.
    pub fn mode(&self, mode: &str) {
        for state in APPLICATION_STATE {
            let _ = fs::remove_file(self.root.join(state));
        }
        fs::write(self.root.join("hdc-mode"), format!("{mode}\n")).unwrap();
    }
}

/// A fixture file as it stood before the continuations settled their debts:
/// the ledger without its settlement members, and a continued Job's record
/// without its recovery load's timeline entry and with its residue still
/// owed.
fn before_continuations(path: &str, bytes: Vec<u8>, continued: &[String]) -> Vec<u8> {
    if path == "artifacts/cleanup-debt.json" {
        let text = String::from_utf8(bytes).unwrap();
        let kept: Vec<&str> = text
            .split('\n')
            .filter(|line| {
                !SETTLEMENT
                    .iter()
                    .any(|key| line.trim_start().starts_with(&format!("\"{key}\"")))
            })
            .collect();
        return kept.join("\n").into_bytes();
    }
    if continued
        .iter()
        .any(|job| path == format!("store/jobs/{job}/job-record.json"))
    {
        let text = String::from_utf8(bytes).unwrap();
        let recovered = ",\n    \"recovered: journal clean\"\n  ]";
        let settled = "\"outstandingResidueCount\" : 0,";
        assert!(text.contains(recovered) && text.contains(settled), "{path}");
        return text
            .replace(recovered, "\n  ]")
            .replace(settled, "\"outstandingResidueCount\" : 1,")
            .into_bytes();
    }
    bytes
}

/// Every recorded request of the oracle `name` before its cleanup debt
/// continuations, answered in order by the Rust owners: `exchanges` of them,
/// each answered as Swift answered it, message included. The fake must have
/// received Swift's first `calls` calls, each Job must have consumed its one
/// use before its first mutation (every later mutation of its run continued
/// under it), and everything the replay leaves below the root must be
/// Swift's byte for byte: for the Jobs of the `continued` cases, whose debts
/// the continuations settle, their record and index row as they stood
/// before (the continuation's recovery load appends `recovered: journal
/// clean`, and its two persists count the settled residue), and the ledger
/// without its settlement members.
pub fn assert_replays_before_continuations(
    name: &str,
    continued: &[&str],
    exchanges: usize,
    calls: usize,
) {
    let _lock = debug_hap::exclusive();
    let fixture = super::fixture(name);
    let cases = document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc(&owners.dispatch);
    let admitter = owners.admitter(&hdc, &owners.default_root);
    let publisher = owners.publisher();
    let runner = owners.runner(&hdc, &publisher, true);
    let reader = JobResultReader {
        jobs: &owners.jobs,
        artifacts: &owners.artifacts,
    };
    let (mut differences, mut replayed) = (Vec::new(), 0);
    for exchange in cases["exchanges"].as_array().unwrap() {
        let (name, method) = (&exchange["name"], exchange["method"].as_str().unwrap());
        if method.starts_with("cleanupDebt.") {
            continue;
        }
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
            other => panic!("{name}: the oracle sent {other}"),
        };
        if actual != exchange["answer"] {
            differences.push(format!(
                "{name}:\n  swift {}\n  rust  {actual}",
                exchange["answer"]
            ));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    assert_eq!(
        replayed, exchanges,
        "every exchange before the continuations"
    );

    // The fake received Swift's calls, in order, up to the continuations.
    let swift = fs::read_to_string(fixture.join("hdc-invocations.log")).unwrap();
    let before: String = swift.split_inclusive('\n').take(calls).collect();
    assert_eq!(owners.calls(), before, "the fake's calls");
    assert_eq!(
        fs::read(owners.root.join("targets-state/targets.json")).unwrap(),
        fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        "the Target document"
    );

    // Each Job consumed its one use before its first mutation; every later
    // mutation of its run continued under it.
    for (case, job) in cases["jobs"].as_object().unwrap() {
        let timeline = owners.record(job.as_str().unwrap())["timeline"].clone();
        let consumed = timeline
            .as_array()
            .unwrap()
            .iter()
            .filter(|line| *line == "capability consumed before first mutation")
            .count();
        assert_eq!(consumed, 1, "{case}");
    }

    let continued: Vec<String> = continued
        .iter()
        .map(|case| cases["jobs"][case].as_str().unwrap().to_owned())
        .collect();
    let Owners {
        jobs,
        root,
        default_root,
        ..
    } = owners;
    drop(jobs);
    super::assert_leftovers_with(
        &fixture,
        &root,
        &default_root,
        |path, bytes| before_continuations(path, bytes, &continued),
        |index| {
            // A continued Job's row as its last persist before them left it:
            // an earlier version, holding the record as it stood.
            for row in index["rows"].as_array_mut().unwrap() {
                let Some(job) = continued.iter().find(|job| row["jobId"] == job.as_str()) else {
                    continue;
                };
                let version = row["version"].as_i64().unwrap();
                row["version"] = json!(version - CONTINUATION_PERSISTS);
                let path = format!("store/jobs/{job}/job-record.json");
                let record = fs::read(fixture.join(&path)).unwrap();
                row["recordSHA256"] =
                    json!(sha256_hex(&before_continuations(&path, record, &continued)));
            }
        },
    );
}
