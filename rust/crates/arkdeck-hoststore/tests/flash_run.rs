//! The Swift Flash run oracle (`rust/tests/fixtures/flash-run`, recorded by
//! `FlashRunOracleContractTests`) replayed through the Rust Runtime's owners,
//! over the same fixed root and with the same scripted lane and facts
//! (`support/flash_lane.rs`). Each story starts from the root the oracle laid
//! down — the Flash plan oracle's imported bundle and Target store, and empty
//! Job, Session and Session owner roots — and each of its exchanges is sent
//! while the fakes answer as it recorded. Every answer must be Swift's, and
//! so must what the fakes were asked and what the story leaves below the root.
//!
//! The stories replayed here are the ones this Runtime serves; the two
//! complete-overwrite recovery stories wait for the slice that admits a
//! superseding recovery (DEC-016).
#![cfg(target_os = "macos")]

mod support;

use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, FlashAdmitter, FlashExecution, FlashPlanner,
    FlashPlanning, FlashReconciler, FlashRunner, ImportUploadStore, JobAdmitter, JobCanceller,
    JobPlanner, JobReconciler, JobResultReader, JobRunner, JobStore, MutationAuthority,
    MutationExecution, SessionPublisher, SessionStore, StorageClaims, TargetStore,
    recover_active_jobs,
};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use support::OracleProbe;
use support::flash_lane::{FakeHost, FakeLane, Fakes, Script, TOOLCHAIN};

const ROOT: &str = "/private/tmp/arkdeck-flash-run-oracle";
/// Serializes every user of the fixed root, Swift producers included.
const LOCK: &str = "/private/tmp/arkdeck-flash-run-oracle.lock";
/// Every story the oracle recorded, in its order.
const STORIES: [&str; 8] = [
    "admission",
    "canonical",
    "alias",
    "failures",
    "reconcile",
    "recovery",
    "recoveryAlias",
    "cancel",
];

fn fixture() -> PathBuf {
    support::fixture("flash-run")
}

fn now() -> Option<String> {
    Some("2026-09-25T00:00:00Z".into())
}

fn precise_now() -> Option<String> {
    Some("2026-09-25T00:00:00.000Z".into())
}

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

/// The root as every story finds it: the inputs laid down with their modes,
/// the Job, Session and Session owner roots empty.
fn lay_down() -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    for directory in [
        "",
        "targets-state",
        "artifacts",
        "store",
        "Sessions",
        "session-owner",
    ] {
        let path = root.join(directory);
        fs::create_dir(&path).unwrap();
        support::chmod(&path, 0o700);
    }
    for input in support::document(&fixture(), "inputs.json")
        .as_array()
        .unwrap()
    {
        let path = input["path"].as_str().unwrap();
        let destination = root.join(path);
        fs::create_dir_all(destination.parent().unwrap()).unwrap();
        fs::write(
            &destination,
            fs::read(fixture().join("inputs").join(path)).unwrap(),
        )
        .unwrap();
        let mode = u32::from_str_radix(input["mode"].as_str().unwrap(), 8).unwrap();
        fs::set_permissions(&destination, fs::Permissions::from_mode(mode)).unwrap();
    }
    // Every directory the inputs name is owner-only, as the oracle made it.
    for path in walk(&root)
        .into_iter()
        .filter(|(_, kind, _)| kind == "directory")
    {
        support::chmod(&root.join(&path.0), 0o700);
    }
    root
}

/// Every entry below `root` by its relative path, sorted: its kind and mode.
fn walk(root: &Path) -> Vec<(String, String, String)> {
    fn visit(root: &Path, directory: &Path, out: &mut Vec<(String, String, String)>) {
        for entry in fs::read_dir(directory).unwrap() {
            let path = entry.unwrap().path();
            let metadata = fs::symlink_metadata(&path).unwrap();
            let kind = if metadata.is_dir() {
                "directory"
            } else if metadata.file_type().is_symlink() {
                "symlink"
            } else {
                "file"
            };
            out.push((
                path.strip_prefix(root)
                    .unwrap()
                    .to_string_lossy()
                    .into_owned(),
                kind.to_owned(),
                format!("{:o}", metadata.mode() & 0o777),
            ));
            if metadata.is_dir() {
                visit(root, &path, out);
            }
        }
    }
    let mut out = Vec::new();
    visit(root, root, &mut out);
    out.sort();
    out
}

/// The owners the daemon composes over the fixed root: the Target, Artifact
/// and Import owners, the Job owner with its capability store, the Session
/// owner and the device holds.
struct Owners {
    root: PathBuf,
    provenance: Value,
    targets: TargetStore,
    artifacts: ArtifactReadStore,
    imports: ImportUploadStore,
    jobs: JobStore,
    capabilities: CapabilityStore,
    sessions: SessionStore,
    claims: StorageClaims,
    probe: OracleProbe,
    holds: DeviceHolds,
    flash: FlashPlanning,
    lane: FakeLane,
    host: FakeHost,
}

impl Owners {
    fn open(root: &Path, fakes: &Fakes) -> Self {
        let store = root.join("store");
        let jobs = JobStore::open_owner(&store).unwrap();
        let provenance = support::document(&fixture(), "provenance.json");
        Self {
            root: root.to_owned(),
            probe: OracleProbe::new(&provenance),
            provenance,
            targets: TargetStore::open(&root.join("targets-state")).unwrap(),
            claims: StorageClaims::default(),
            lane: FakeLane::new(fakes),
            host: FakeHost(fakes.clone()),
            artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
            imports: ImportUploadStore::open(&root.join("artifacts")).unwrap(),
            capabilities: CapabilityStore::open(&store.join("capabilities")).unwrap(),
            jobs,
            sessions: SessionStore::open(&root.join("session-owner"), &root.join("Sessions"))
                .unwrap(),
            holds: DeviceHolds::default(),
            // Swift's lane may flash, its dispatcher has no reason to refuse,
            // and the lane's toolchain is the oracle's.
            flash: FlashPlanning::new(None, || None, Some(TOOLCHAIN.into())),
        }
    }

    fn state_root(&self) -> PathBuf {
        self.root.join("store")
    }

    fn planner<'a>(&'a self, state_root: &'a Path) -> JobPlanner<'a> {
        JobPlanner {
            artifacts: Some(&self.artifacts),
            imports: Some(&self.imports),
            analyzer: None,
            state_root,
            hdc: None,
            workspace: None,
        }
    }

    /// One exchange's answer, as the daemon's control layer answers it.
    fn answer(&self, fakes: &Fakes, method: &str, params: &Map<String, Value>) -> Value {
        let state_root = self.state_root();
        let facts = |target: &str| fakes.facts(target);
        match method {
            "job.plan" => {
                let planner = FlashPlanner {
                    planner: self.planner(&state_root),
                    flash: Some(&self.flash),
                    facts: Some(&facts),
                };
                match planner.handle(params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(refusal) => refused(refusal.code, refusal.message, true),
                }
            }
            "job.submit" => {
                let admitter = FlashAdmitter {
                    admitter: JobAdmitter {
                        planner: self.planner(&state_root),
                        jobs: &self.jobs,
                        now,
                        authority: Some(MutationAuthority {
                            default_root: &state_root,
                            sessions: Some(&self.sessions),
                            capabilities: &self.capabilities,
                            holds: &self.holds,
                        }),
                    },
                    flash: Some(&self.flash),
                    facts: Some(&facts),
                    executes: true,
                };
                match admitter.handle(params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(refusal) => refused(refusal.code, refusal.message, refusal.proven),
                }
            }
            "job.run" => {
                let authority = MutationAuthority {
                    default_root: &state_root,
                    sessions: Some(&self.sessions),
                    capabilities: &self.capabilities,
                    holds: &self.holds,
                };
                let publisher = SessionPublisher {
                    sessions: &self.sessions,
                    claims: &self.claims,
                    probe: &self.probe,
                };
                let runner = FlashRunner {
                    runner: JobRunner {
                        mutation: Some(MutationExecution {
                            authority,
                            state_root: &state_root,
                        }),
                        jobs: &self.jobs,
                        artifacts: &self.artifacts,
                        imports: Some(&self.imports),
                        analyzer: None,
                        quota: self.provenance["quotaBytes"].as_u64().unwrap(),
                        home: self.provenance["home"].as_str().unwrap(),
                        now,
                        precise_now,
                        sessions: Some(&publisher),
                        cancellation: None,
                        after_commit: None,
                        hdc: None,
                        workspace: None,
                    },
                    flash: Some(FlashExecution {
                        planning: &self.flash,
                        facts: &facts,
                        lane: &self.lane,
                        profile_id: self.provenance["profileId"].as_str().unwrap(),
                        host: &self.host,
                        targets: &self.targets,
                    }),
                };
                match runner.handle(params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(refusal) => json!({"ok": false, "error": {
                        "code": refusal.code, "message": refusal.message,
                        "details": refusal.details}}),
                }
            }
            "job.reconcile" => {
                let publisher = SessionPublisher {
                    sessions: &self.sessions,
                    claims: &self.claims,
                    probe: &self.probe,
                };
                let reconciler = FlashReconciler {
                    reconciler: JobReconciler {
                        jobs: &self.jobs,
                        artifacts: &self.artifacts,
                        imports: Some(&self.imports),
                        now,
                        sessions: Some(&publisher),
                        hdc: None,
                        capabilities: Some(&self.capabilities),
                        runner: None,
                    },
                    lane: Some(&self.lane),
                };
                match reconciler.handle(params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(error) => wire(error),
                }
            }
            "job.cancel" => {
                let publisher = SessionPublisher {
                    sessions: &self.sessions,
                    claims: &self.claims,
                    probe: &self.probe,
                };
                let canceller = JobCanceller {
                    jobs: &self.jobs,
                    now,
                    sessions: Some(&publisher),
                };
                match canceller.handle(params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(error) => wire(error),
                }
            }
            "job.status" => match self.jobs.handle_resource(method, params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(error) => wire(error),
            },
            "job.result" | "job.evidence" => {
                let reader = JobResultReader {
                    jobs: &self.jobs,
                    artifacts: &self.artifacts,
                };
                match reader.handle(method, params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(error) => wire(error),
                }
            }
            "artifact.list" => {
                let jobs = &self.jobs;
                match self
                    .artifacts
                    .handle_list(params, &jobs.snapshot_directory(), |job| {
                        jobs.read_snapshot(job).map(|_| ())
                    }) {
                    // The pager's revision is its own; the oracle labels it.
                    Ok(mut result) => {
                        result["snapshotRevision"] = json!("<snapshotRevision>");
                        json!({"ok": true, "result": result})
                    }
                    Err(error) => wire(error),
                }
            }
            "capability.list" | "capability.inspect" => {
                match self.capabilities.handle(method, params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(error) => json!({"ok": false, "error": {
                        "code": error.code, "message": error.message}}),
                }
            }
            other => panic!("this Runtime does not serve {other} for a Flash yet"),
        }
    }
}

/// A read's refusal as the control layer answers it.
fn wire(error: arkdeck_contract::WireError) -> Value {
    let mut body = json!({"code": error.code, "message": error.message});
    if let Some(details) = error.details {
        body["details"] = Value::Object(details);
    }
    json!({"ok": false, "error": body})
}

/// A refusal as the control layer answers it: the zero-dispatch proof where
/// it holds, empty details where it does not.
fn refused(code: &str, message: String, proven: bool) -> Value {
    let details = if proven {
        json!({"phase": "preAdmission", "newDispatchCount": 0})
    } else {
        json!({})
    };
    json!({"ok": false, "error": {"code": code, "message": message, "details": details}})
}

/// The oracle's label for the host's measured prewarm wait.
fn normalized(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(at) = rest.find("consume wait ") {
        let (head, tail) = rest.split_at(at + "consume wait ".len());
        out.push_str(head);
        let digits = tail.bytes().take_while(u8::is_ascii_digit).count();
        if digits > 0 && tail[digits..].starts_with(" ms") {
            out.push_str("<ms>");
            rest = &tail[digits..];
        } else {
            rest = tail;
        }
    }
    out.push_str(rest);
    out
}

fn normalized_value(value: &Value) -> Value {
    serde_json::from_str(&normalized(&value.to_string())).unwrap()
}

/// Replays `story` and returns what differs from Swift, one line each.
fn replay(story: &str) -> Vec<String> {
    let _lock = exclusive();
    play(story)
}

/// Replays `story` over the root the caller holds the lock of, and leaves
/// what it made there.
fn play(story: &str) -> Vec<String> {
    let root = lay_down();
    let cases = support::document(&fixture().join("stories").join(story), "cases.json");
    let fakes = Fakes::default();
    let mut owners = Owners::open(&root, &fakes);
    let mut differences = Vec::new();
    for exchange in cases["exchanges"].as_array().unwrap() {
        let name = exchange["name"].as_str().unwrap();
        let method = exchange["method"].as_str().unwrap();
        fakes.begin(Script::recorded(&exchange["script"]));
        let answer = if method == "<restart>" {
            // The daemon stops and starts again over the same root: new
            // owners and a new lane, the active Jobs recovered before it
            // serves.
            drop(owners);
            owners = Owners::open(&root, &fakes);
            let recovered =
                recover_active_jobs(&owners.jobs, Some(&owners.capabilities), now).unwrap();
            assert!(recovered.quarantined.is_empty() && recovered.refused.is_empty());
            json!({"recovered": recovered
                .statuses
                .iter()
                .map(|status| json!({"jobId": status["jobId"], "state": status["state"]}))
                .collect::<Vec<_>>()})
        } else {
            owners.answer(&fakes, method, exchange["params"].as_object().unwrap())
        };
        let answer = normalized_value(&support::legacy_plan_answer(answer));
        if answer != exchange["answer"] {
            differences.push(format!(
                "{story}/{name}:\n  swift {}\n  rust  {answer}",
                exchange["answer"]
            ));
        }
        let (lane, dispatch) = fakes.calls();
        if json!(lane) != exchange["laneCalls"] || json!(dispatch) != exchange["dispatchCalls"] {
            differences.push(format!(
                "{story}/{name} calls:\n  swift {} {}\n  rust  {lane:?} {dispatch:?}",
                exchange["laneCalls"], exchange["dispatchCalls"]
            ));
        }
    }
    drop(owners);
    differences.extend(leftovers(story, &root));
    differences
}

/// The Artifact pager's snapshots: Swift keeps them in the Artifact root,
/// labelled in the oracle; this Runtime keeps its pager in the Job root.
const SWIFT_SNAPSHOTS: &str = "artifacts/.imports-v1/artifact-snapshots/snapshot-";
const RUST_SNAPSHOTS: &str = "store/cli-job-snapshots/snapshot-";

/// What Swift's daemon leaves below the root that no story made, and this
/// Runtime does not: the Job directory its engine creates when it starts;
/// the empty Target store below the state root its every status read opens
/// (`recoveryEpochIndexes`); what its Artifact reads write, a Job's empty
/// Artifact directory and a payload's verification cache; and its pager's
/// snapshots.
fn swift_incidental(path: &str) -> bool {
    matches!(
        path,
        "store/jobs"
            | "store/targets"
            | "store/targets/.target-display-names.lock"
            | "store/targets/target-display-names.json"
            | "artifacts/.imports-v1/artifact-snapshots"
    ) || path.starts_with(SWIFT_SNAPSHOTS)
        || path.ends_with("/.payload-verification-v1.json")
        || path
            .strip_prefix("artifacts/job-")
            .is_some_and(|job| job.len() == 32 && !job.contains('/'))
}

/// What this Runtime's owners leave that Swift's do not: each owner's lock,
/// the empty Session retention catalog a Session owner writes when it opens
/// (Swift writes it at its first publication), and the pager's snapshots.
fn rust_incidental(path: &str) -> bool {
    matches!(
        path,
        "store/.rust-job-owner.lock"
            | "artifacts/.imports-v1/.owner.lock"
            | "session-owner/.session-storage.lock"
            | "Sessions/.arkdeck-retention-catalog.lock"
            | "Sessions/.arkdeck-retention-catalog.json"
            | "store/cli-job-snapshots"
            | "store/cli-job-snapshots/.snapshots.lock"
    ) || path.starts_with(RUST_SNAPSHOTS)
}

/// A Flash record's timeline measures how long its run waited for the lane's
/// prewarm (`consume wait <ms> ms`), which the oracle labels wherever it
/// records text; the Job index's `recordSHA256` hashes the record as the
/// store holds it. A row whose digest differs is held to Swift's by the wait
/// that reproduces it, every other byte unchanged: the recorded wait, which
/// the fake lane makes 0, first, then any one wait.
fn measured_waits(store: &Path, index: &mut Value, swift: &Value) {
    const LABEL: &str = "consume wait ";
    let expected: BTreeMap<String, String> = swift["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            (
                row["jobId"].as_str().unwrap().to_owned(),
                row["recordSHA256"].as_str().unwrap_or_default().to_owned(),
            )
        })
        .collect();
    let mut db =
        arkdeck_platform::HostSqlite::open(&store.join("runtime-jobs.sqlite3"), true, false)
            .unwrap();
    let mut records = BTreeMap::new();
    for row in db
        .query(
            "SELECT job_id, initial_record_json FROM runtime_job",
            &[],
            64 << 20,
        )
        .unwrap()
    {
        if let (
            arkdeck_platform::SqliteValue::Text(job),
            arkdeck_platform::SqliteValue::Blob(bytes),
        ) = (&row[0], &row[1])
        {
            records.insert(job.clone(), String::from_utf8_lossy(bytes).into_owned());
        }
    }
    let digest =
        |text: &str| arkdeck_contract::sha256_hex(&support::machine_independent(text.as_bytes()));
    // `text` with its measured waits spelled `waits` in turn.
    let spelled = |text: &str, waits: &dyn Fn(usize) -> u32| {
        let mut out = String::new();
        let mut rest = text;
        let mut seen = 0;
        while let Some(at) = rest.find(LABEL) {
            let (head, tail) = rest.split_at(at + LABEL.len());
            out.push_str(head);
            let digits = tail.bytes().take_while(u8::is_ascii_digit).count();
            if digits > 0 && tail[digits..].starts_with(" ms") {
                out.push_str(&waits(seen).to_string());
                seen += 1;
                rest = &tail[digits..];
            } else {
                rest = tail;
            }
        }
        out.push_str(rest);
        (out, seen)
    };
    for row in index["rows"].as_array_mut().unwrap() {
        let job = row["jobId"].as_str().unwrap_or_default().to_owned();
        let (Some(wanted), Some(record)) = (expected.get(&job), records.get(&job)) else {
            continue;
        };
        if row["recordSHA256"] == json!(wanted) || !record.contains(LABEL) {
            continue;
        }
        let (zero, waits) = spelled(record, &|_| 0);
        let found = digest(&zero) == *wanted
            || (waits == 1
                && (1..=10_000).any(|wait| digest(&spelled(record, &|_| wait).0) == *wanted));
        if found {
            row["recordSHA256"] = json!(wanted);
        }
    }
}

/// What `story` left below the root against what Swift's left: the Job
/// index, every entry's kind and mode, and every regular file's bytes, each
/// Job record's machine facts labelled. A payload's verification cache pins
/// its inode, so only its kind and mode are compared. What either daemon
/// leaves that no story made is declared (`swift_incidental`,
/// `rust_incidental`) and left out where only that daemon has it; the two
/// pagers still made as many snapshots.
fn leftovers(story: &str, root: &Path) -> Vec<String> {
    let recorded = fixture().join("stories").join(story);
    let mut differences = Vec::new();
    let mut index = support::index(&root.join("store"));
    let swift_index = support::document(&recorded, "index.json");
    measured_waits(&root.join("store"), &mut index, &swift_index);
    if index != swift_index {
        differences.push(format!("{story}: the Job index differs: {index}"));
    }
    let tree: Vec<Value> = walk(root)
        .into_iter()
        .filter(|(path, _, _)| !path.starts_with("store/runtime-jobs.sqlite3"))
        .map(|(path, kind, mode)| json!({"path": path, "kind": kind, "mode": mode}))
        .collect();
    let swift_tree = support::document(&recorded, "tree.json");
    let swift_tree = swift_tree.as_array().unwrap();
    let path = |entry: &Value| entry["path"].as_str().unwrap_or_default().to_owned();
    let rust: Vec<&Value> = tree
        .iter()
        .filter(|entry| !swift_tree.contains(entry) && !rust_incidental(&path(entry)))
        .collect();
    let swift: Vec<&Value> = swift_tree
        .iter()
        .filter(|entry| !tree.contains(entry) && !swift_incidental(&path(entry)))
        .collect();
    if !rust.is_empty() || !swift.is_empty() {
        differences.push(format!(
            "{story}: the tree differs\n  swift only {swift:?}\n  rust only  {rust:?}"
        ));
    }
    let snapshots = |entries: &[Value], prefix: &str| {
        entries
            .iter()
            .filter(|entry| path(entry).starts_with(prefix))
            .count()
    };
    let (swift_pages, rust_pages) = (
        snapshots(swift_tree, SWIFT_SNAPSHOTS),
        snapshots(&tree, RUST_SNAPSHOTS),
    );
    if swift_pages != rust_pages {
        differences.push(format!(
            "{story}: Swift's pager kept {swift_pages} snapshots, this Runtime's {rust_pages}"
        ));
    }
    let mut files = BTreeMap::new();
    for (path, kind, _) in walk(root) {
        if kind != "file"
            || path.starts_with("store/runtime-jobs.sqlite3")
            || path.ends_with("/.payload-verification-v1.json")
        {
            continue;
        }
        let bytes = fs::read(root.join(&path)).unwrap();
        let bytes = if path.ends_with("/job-record.json") {
            support::machine_independent(&bytes)
        } else {
            bytes
        };
        files.insert(path, normalized(&String::from_utf8_lossy(&bytes)));
    }
    let files_root = recorded.join("files");
    let mut swift_files = BTreeMap::new();
    for (path, kind, _) in walk(&files_root) {
        if kind == "file" {
            swift_files.insert(
                path.clone(),
                String::from_utf8_lossy(&fs::read(files_root.join(&path)).unwrap()).into_owned(),
            );
        }
    }
    for path in files
        .keys()
        .chain(swift_files.keys())
        .collect::<std::collections::BTreeSet<_>>()
    {
        let declared = match (files.contains_key(path), swift_files.contains_key(path)) {
            (true, false) => rust_incidental(path),
            (false, true) => swift_incidental(path),
            _ => false,
        };
        if !declared && files.get(path) != swift_files.get(path) {
            differences.push(format!(
                "{story}: {path}\n  swift {:?}\n  rust  {:?}",
                swift_files.get(path),
                files.get(path)
            ));
        }
    }
    differences
}

#[test]
fn the_oracle_records_every_story() {
    let provenance = support::document(&fixture(), "provenance.json");
    assert_eq!(provenance["stories"], json!(STORIES));
    for story in STORIES {
        assert!(
            fixture()
                .join("stories")
                .join(story)
                .join("cases.json")
                .is_file(),
            "{story}"
        );
    }
}

/// Every Flash refusal before admission is Swift's, message and details, and
/// nothing is admitted, issued, reserved or dispatched.
#[test]
fn every_admission_refusal_is_swifts() {
    let differences = replay("admission");
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}

/// Two ordinary Flashes of the canonical operation, reviewed, deduplicated
/// and run: the Runtime's one-use capability issued and consumed before the
/// delegated write, the completed plan projected onto every later step, the
/// diagnostics captured once and refused once, and everything each run
/// leaves, Swift's.
#[test]
fn a_canonical_flash_runs_as_swifts() {
    let differences = replay("canonical");
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}

/// The compatibility alias with basic verification, whose diagnostics are
/// not selected.
#[test]
fn an_alias_flash_runs_as_swifts() {
    let differences = replay("alias");
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}

/// An admitted Flash cancelled before it runs, closed with zero dispatch and
/// no use settled, then the next one run under the same unspent capability.
#[test]
fn a_flash_cancelled_before_it_runs_is_closed_as_swifts() {
    let differences = replay("cancel");
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}

/// A lost controller parks the Flash, the daemon restarts, and passive
/// reconciliation of the exact daemon job settles each Job as Swift's: no
/// terminal yet, then the completed plan the resumed run projects; a daemon
/// job cancelled safely; an unreachable daemon, then a failure without proof.
#[test]
fn a_lost_flash_is_reconciled_as_swifts() {
    let differences = replay("reconcile");
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}

/// Every way a delegated Flash ends short of success, one Job each over one
/// store, each capability outcome and generation as Swift's.
#[test]
fn every_flash_failure_ends_as_swifts() {
    let differences = replay("failures");
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}

/// One exchange of a recorded story, by its name.
fn recorded(story: &str, name: &str) -> Value {
    let cases = support::document(&fixture().join("stories").join(story), "cases.json");
    cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == name)
        .unwrap_or_else(|| panic!("{story} records no {name}"))
        .clone()
}

/// A Flash dispatches only inside its Target's mutation lane: while another
/// holder keeps the lane, its run waits in the lane's queue, and nothing but
/// the archive prewarm (which Swift starts before the lane) is asked of the
/// lane; once the lane is free, the run prepares and drives its daemon job.
#[test]
fn a_flash_runs_only_inside_its_targets_mutation_lane() {
    let _lock = exclusive();
    let root = lay_down();
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    fakes.begin(Script::default());
    let submitted = owners.answer(
        &fakes,
        "job.submit",
        recorded("canonical", "submit")["params"]
            .as_object()
            .unwrap(),
    );
    let job = submitted["result"]["jobId"].as_str().unwrap().to_owned();
    let target = owners.jobs.read_snapshot(&job).unwrap().request["target"]["targetId"]
        .as_str()
        .unwrap()
        .to_owned();
    let key = owners.targets.mutation_lane_key(&target).unwrap();
    let until = |what: &str, condition: &dyn Fn() -> bool| {
        let started = Instant::now();
        while !condition() {
            assert!(
                started.elapsed() < Duration::from_secs(60),
                "never reached: {what}"
            );
            std::thread::yield_now();
        }
    };
    fakes.begin(Script::default());
    let run = json!({"jobId": job});
    let (answer, waited) = std::thread::scope(|scope| {
        let lane = owners
            .targets
            .enter_mutation_lane(&target, "lane-test-holder", None)
            .unwrap()
            .unwrap();
        let running = scope.spawn(|| owners.answer(&fakes, "job.run", run.as_object().unwrap()));
        until("the Flash waiting in its Target's lane", &|| {
            owners.targets.mutation_lane_queue(&key).contains(&job)
        });
        let waited = fakes.calls();
        drop(lane);
        (running.join().unwrap(), waited)
    });
    assert!(
        waited.0.iter().all(|call| call.starts_with("prewarm ")) && waited.1.is_empty(),
        "the lane was asked for more than the prewarm while the run waited: {waited:?}"
    );
    assert_eq!(answer["result"]["state"], "succeeded", "{answer}");
    assert!(
        fakes
            .calls()
            .0
            .iter()
            .any(|call| call.starts_with("perform flash-partitions ")),
        "{:?}",
        fakes.calls()
    );
}

/// Until the recovery slice serves DEC-016, a Flash whose outcome is unknown
/// blocks every later Flash of its binding through the capability lineage:
/// the request is refused before admission, with nothing issued, admitted or
/// dispatched.
#[test]
fn a_flash_after_an_unknown_one_is_refused_by_its_lineage() {
    let _lock = exclusive();
    let differences = play("failures");
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    let root = PathBuf::from(ROOT);
    let fakes = Fakes::default();
    let owners = Owners::open(&root, &fakes);
    let index = support::index(&root.join("store"));
    let store = root.join("store/capabilities");
    let capabilities = (
        fs::read(store.join("runtime-capabilities.json")).unwrap(),
        fs::read(store.join("runtime-capabilities.ledger")).unwrap(),
    );
    let mut request: Value = serde_json::from_str(
        recorded("failures", "prewarmRefused.submit")["params"]["requestJson"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    request["requestId"] = json!("req-flash-after-unknown");
    request["idempotencyKey"] = json!("idem-flash-after-unknown");
    fakes.begin(Script::default());
    let answer = owners.answer(
        &fakes,
        "job.submit",
        json!({"requestJson": request.to_string()})
            .as_object()
            .unwrap(),
    );
    assert_eq!(answer["error"]["code"], "admissionDenied", "{answer}");
    assert!(
        answer["error"]["message"].as_str().is_some_and(
            |message| message.starts_with("automatic Runtime target lineage is blocked:")
        ),
        "{answer}"
    );
    assert_eq!(
        answer["error"]["details"],
        json!({"phase": "preAdmission", "newDispatchCount": 0})
    );
    assert_eq!(fakes.calls(), (Vec::new(), Vec::new()));
    assert_eq!(support::index(&root.join("store")), index);
    assert_eq!(
        (
            fs::read(store.join("runtime-capabilities.json")).unwrap(),
            fs::read(store.join("runtime-capabilities.ledger")).unwrap(),
        ),
        capabilities
    );
}
