//! Replays the Swift oracle of `workspace.create-checkpoint@1` and
//! `workspace.sweep-isolated-copies@1`
//! (`rust/tests/fixtures/workspace-checkpoint-oracle`, recorded by
//! `WorkspaceCheckpointOracleContractTests`) against the Rust planner,
//! admitter, runner, reconciler and result reader over the same fixed root,
//! profiles, stand-in tools and clock: every answer must be Swift's (the
//! plan's additive review digest aside), and what the Runtime keeps
//! afterwards — the capability store, the published products, the sealed
//! archive, the copies' audit records and what each copy's root still holds,
//! and the durable records of the two Jobs whose receipt was lost — Swift's
//! byte for byte.
//!
//! The same binary pins what the oracle cannot show: a checkpoint tool whose
//! bytes changed after its pin is never run; no capability a caller names —
//! not even a grant the store holds for exactly that tree and plan — admits
//! a checkpoint; a copy whose tree the Runtime can no longer vouch for is
//! never swept; and the host's own `/usr/bin/git` and `/usr/bin/bsdtar`
//! checkpoint a production-shaped project.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, JobAdmitter, JobPlanner, JobReconciler,
    JobResultReader, JobRunner, JobStore, MutationAuthority, MutationExecution, ProfilePresets,
    ToolFailure, ToolInvocation, ToolReceipt, VerifiedToolDispatch, WorkspaceCommandPreset,
    WorkspaceComposition, WorkspaceProfile, WorkspaceToolDispatch,
};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, UNIX_EPOCH};
use support::chmod;

/// The recording's fixed root: the profiles name the source trees by path,
/// and an archive checkpoint's argv names its files' root and destination.
const ROOT: &str = "/private/tmp/arkdeck-workspace-checkpoint-oracle";
const LOCK: &str = "/private/tmp/arkdeck-workspace-checkpoint-oracle.lock";
const TIMESTAMP: &str = "2026-09-25T00:00:00Z";
/// The archived files' modification time: 2026-09-25T00:00:00Z.
const FILE_DATE: u64 = 1_790_294_400;
const PROJECT: &str = "CheckpointOracleProject";
const ARCHIVE_PROJECT: &str = "ArchiveOracleProject";
const PROFILE: &str = "workspace-checkpoint-oracle@1";
const SCOPE: &str = "entry/src/main/ets/**";
const INDEX: &str = "entry/src/main/ets/pages/Index.ets";
const ABILITY: &str = "entry/src/main/ets/entryability/EntryAbility.ets";
const INDEX_SOURCE: &str = "@Entry\n@Component\nstruct Index {\n  build() {}\n}\n";
const ABILITY_SOURCE: &str = "export default class EntryAbility {}\n";
const LOST_AFTER: &str =
    "dispatch outcome unobservable: the oracle lost the receipt after the child ran";

fn oracle_now() -> Option<String> {
    Some(TIMESTAMP.into())
}

fn text(path: &Path) -> String {
    path.to_str().unwrap().to_owned()
}

/// Serializes every user of the fixed root in this binary.
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

/// Whether the workspace dispatch hands its receipt back — a tool's or the
/// sweep's — as the Swift oracle's receipt-losing dispatcher decides it,
/// and how many children and sweeps it let run.
#[derive(Default)]
struct Loss {
    lost: AtomicBool,
    started: AtomicUsize,
    swept: AtomicUsize,
}

struct LosingDispatch(Arc<Loss>);

impl WorkspaceToolDispatch for LosingDispatch {
    fn dispatch(&self, invocation: &ToolInvocation<'_>) -> Result<ToolReceipt, ToolFailure> {
        self.0.started.fetch_add(1, Ordering::SeqCst);
        let receipt = VerifiedToolDispatch.dispatch(invocation)?;
        if self.0.lost.load(Ordering::SeqCst) {
            return Err(ToolFailure::OutcomeUnknown(LOST_AFTER.into()));
        }
        Ok(receipt)
    }

    fn host_receipt(&self, _step: &str) -> Result<(), ToolFailure> {
        self.0.swept.fetch_add(1, Ordering::SeqCst);
        if self.0.lost.load(Ordering::SeqCst) {
            return Err(ToolFailure::OutcomeUnknown(LOST_AFTER.into()));
        }
        Ok(())
    }
}

/// A private root, removed when the test ends.
struct Root(PathBuf);

impl Root {
    fn fixed() -> Self {
        let root = PathBuf::from(ROOT);
        let _ = fs::remove_dir_all(&root);
        Self::make(root)
    }
    fn temporary(label: &str) -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-workspace-checkpoint-{label}-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        Self::make(root)
    }
    fn make(root: PathBuf) -> Self {
        for directory in [
            root.clone(),
            root.join("artifacts"),
            root.join("jobs-state"),
        ] {
            fs::create_dir(&directory).unwrap();
            chmod(&directory, 0o700);
        }
        Self(root)
    }
    fn join(&self, relative: &str) -> PathBuf {
        self.0.join(relative)
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// One source file, owner-writable and world-readable, with the fixed
/// modification time an archive records.
fn write_source(path: &Path, contents: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, contents).unwrap();
    chmod(path, 0o644);
    File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(UNIX_EPOCH + Duration::from_secs(FILE_DATE))
        .unwrap();
}

/// One OpenHarmony-shaped project: two ArkTS sources inside the profile's
/// scope and a build profile outside it.
fn tree(source: &Path) -> PathBuf {
    write_source(&source.join(ABILITY), ABILITY_SOURCE);
    write_source(&source.join(INDEX), INDEX_SOURCE);
    write_source(&source.join("build-profile.json5"), "{}\n");
    source.canonicalize().unwrap()
}

/// The host's git in the closed environment the stand-in gives it, with the
/// author and the clock fixed, as the Swift oracle runs it.
fn git(arguments: &[&str], directory: &Path) -> Vec<u8> {
    let output = Command::new("/usr/bin/git")
        .arg("-C")
        .arg(directory)
        .args(arguments)
        .env_clear()
        .envs([
            ("PATH", "/usr/bin:/bin"),
            ("LANG", "C"),
            ("LC_ALL", "C"),
            ("GIT_CONFIG_NOSYSTEM", "1"),
            ("GIT_CONFIG_GLOBAL", "/dev/null"),
            ("GIT_AUTHOR_NAME", "Oracle"),
            ("GIT_AUTHOR_EMAIL", "oracle@invalid.example"),
            ("GIT_COMMITTER_NAME", "Oracle"),
            ("GIT_COMMITTER_EMAIL", "oracle@invalid.example"),
            ("GIT_AUTHOR_DATE", "2026-09-25T00:00:00Z"),
            ("GIT_COMMITTER_DATE", "2026-09-25T00:00:00Z"),
        ])
        .stderr(Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success(), "git {arguments:?}");
    output.stdout
}

/// The fixture's stand-in tools, executable, beside the sources.
struct Tools {
    grep: PathBuf,
    sed: PathBuf,
    git: PathBuf,
    bsdtar: PathBuf,
}

fn tools(root: &Path, fixture: &Path) -> Tools {
    let directory = root.join("tools");
    fs::create_dir(&directory).unwrap();
    for name in ["grep", "sed", "git", "bsdtar"] {
        fs::copy(fixture.join(format!("{name}.sh")), directory.join(name)).unwrap();
        chmod(&directory.join(name), 0o755);
    }
    let directory = directory.canonicalize().unwrap();
    Tools {
        grep: directory.join("grep"),
        sed: directory.join("sed"),
        git: directory.join("git"),
        bsdtar: directory.join("bsdtar"),
    }
}

fn preset(id: &str, tool: &Path) -> WorkspaceCommandPreset {
    WorkspaceCommandPreset::hashing(id, &text(tool), None, &[], 30).unwrap()
}

/// The oracle's two profiles, in the daemon's order (by reference): a plain
/// project checkpointed as a sealed archive, and a project inside a larger
/// git checkout checkpointed as a git object.
fn profiles(source: &Path, plain: &Path, tools: &Tools) -> Vec<WorkspaceProfile> {
    let archive = WorkspaceProfile::primary(
        PROFILE,
        ARCHIVE_PROJECT,
        &text(plain),
        &[SCOPE],
        preset("source-inspection", &tools.grep),
        preset("unified-diff", &tools.grep),
        ProfilePresets {
            archive_checkpoint: Some(preset("sealed-source-archive", &tools.bsdtar)),
            ..ProfilePresets::default()
        },
    )
    .unwrap();
    let checkout = WorkspaceProfile::primary(
        PROFILE,
        PROJECT,
        &text(source),
        &[SCOPE],
        preset("source-inspection", &tools.grep),
        preset("unified-diff", &tools.grep),
        ProfilePresets {
            source_control: Some(preset("git", &tools.git)),
            source_reader: Some(preset("source-range", &tools.sed)),
            archive_checkpoint: Some(preset("sealed-source-archive", &tools.bsdtar)),
            ..ProfilePresets::default()
        },
    )
    .unwrap();
    vec![archive, checkout]
}

/// The Runtime around one composition, as the Swift oracle composed its
/// engine: a capability store beside the Job state, no Session writer, no
/// HDC.
struct Owners {
    root: Root,
    jobs: JobStore,
    artifacts: ArtifactReadStore,
    capabilities: CapabilityStore,
    holds: DeviceHolds,
    workspace: WorkspaceComposition,
}

impl Owners {
    fn new(root: Root, workspace: WorkspaceComposition) -> Self {
        let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
        // The capability store opens after the Job store, as the daemon's.
        let capabilities = CapabilityStore::open(&root.join("jobs-state/capabilities")).unwrap();
        Self {
            jobs,
            artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
            capabilities,
            holds: DeviceHolds::default(),
            workspace,
            root,
        }
    }
    fn default_root(&self) -> PathBuf {
        self.root.join("jobs-state")
    }
    fn authority<'a>(&'a self, default_root: &'a Path) -> MutationAuthority<'a> {
        MutationAuthority {
            default_root,
            sessions: None,
            capabilities: &self.capabilities,
            holds: &self.holds,
        }
    }
    fn planner(&self) -> JobPlanner<'_> {
        JobPlanner {
            artifacts: Some(&self.artifacts),
            imports: None,
            analyzer: None,
            state_root: &self.root.0,
            hdc: None,
            workspace: Some(&self.workspace),
        }
    }
    fn plan(&self, params: &Value) -> Value {
        match self.planner().handle(params.as_object().unwrap()) {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(refusal) => refused(refusal.code, &refusal.message, Some(proven())),
        }
    }
    fn submit(&self, params: &Value) -> Value {
        let default_root = self.default_root();
        let admitter = JobAdmitter {
            planner: self.planner(),
            jobs: &self.jobs,
            now: oracle_now,
            authority: Some(self.authority(&default_root)),
        };
        match admitter.handle(params.as_object().unwrap()) {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(refusal) => refused(
                refusal.code,
                &refusal.message,
                Some(if refusal.proven { proven() } else { Map::new() }),
            ),
        }
    }
    fn run(&self, job: &str) -> Value {
        let default_root = self.default_root();
        let runner = JobRunner {
            mutation: Some(MutationExecution {
                authority: self.authority(&default_root),
                state_root: &self.root.0,
            }),
            jobs: &self.jobs,
            artifacts: &self.artifacts,
            imports: None,
            analyzer: None,
            quota: 8 * 1024 * 1024 * 1024,
            home: "/nonexistent-home",
            now: oracle_now,
            precise_now: oracle_now,
            sessions: None,
            cancellation: None,
            after_commit: None,
            hdc: None,
            workspace: Some(&self.workspace),
        };
        match runner.handle(json!({"jobId": job}).as_object().unwrap()) {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(refusal) => refused(refusal.code, &refusal.message, Some(refusal.details)),
        }
    }
    fn reconcile(&self, job: &str) -> Value {
        let reconciler = JobReconciler {
            jobs: &self.jobs,
            artifacts: &self.artifacts,
            imports: None,
            now: oracle_now,
            sessions: None,
            hdc: None,
            capabilities: Some(&self.capabilities),
            runner: None,
        };
        match reconciler.handle(json!({"jobId": job}).as_object().unwrap()) {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(error) => refused(&error.code, &error.message, error.details),
        }
    }
    fn result(&self, job: &str) -> Value {
        let reader = JobResultReader {
            jobs: &self.jobs,
            artifacts: &self.artifacts,
        };
        match reader.handle("job.result", json!({"jobId": job}).as_object().unwrap()) {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(error) => refused(&error.code, &error.message, error.details),
        }
    }
    fn record(&self, job: &str) -> Value {
        self.jobs.read_snapshot(job).unwrap().value().unwrap()
    }
}

fn proven() -> Map<String, Value> {
    Map::from_iter([
        ("phase".into(), json!("preAdmission")),
        ("newDispatchCount".into(), json!(0)),
    ])
}

fn refused(code: &str, message: &str, details: Option<Map<String, Value>>) -> Value {
    let mut error = json!({"code": code, "message": message});
    if let Some(details) = details {
        error["details"] = Value::Object(details);
    }
    json!({"ok": false, "error": error})
}

/// The regular files of one directory, hidden ones aside, by name.
fn files(directory: &Path) -> Vec<(String, Vec<u8>)> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut found: Vec<(String, Vec<u8>)> = entries
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            !path.file_name().unwrap().to_string_lossy().starts_with('.') && path.is_file()
        })
        .map(|path| {
            (
                path.file_name().unwrap().to_string_lossy().into_owned(),
                fs::read(&path).unwrap(),
            )
        })
        .collect();
    found.sort();
    found
}

/// The names below one directory, sorted.
fn names(directory: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

fn request_id(params: &Value) -> Option<String> {
    let document: Value = serde_json::from_str(params["requestJson"].as_str()?).ok()?;
    document["requestId"].as_str().map(str::to_owned)
}

/// A typed request document, as the Swift oracle writes it.
fn request(label: &str, operation: &str, inputs: Value, capability: Option<&str>) -> Value {
    let mut document = json!({
        "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
        "requestId": format!("request-{label}"),
        "idempotencyKey": format!("idempotency-{label}"),
        "target": {"targetId": "workspace-host"},
        "operation": {"id": operation, "version": 1},
        "inputs": inputs,
        "requestedOutputs": ["derivedArtifacts"],
    });
    if let Some(capability) = capability {
        document["authorization"] = json!({"capabilityId": capability});
    }
    json!({"requestJson": document.to_string()})
}

/// The oracle's fixed root: the project inside a committed git checkout, the
/// plain project, and the stand-in tools.
struct Oracle {
    source: PathBuf,
    plain: PathBuf,
    tools: Tools,
}

fn oracle(root: &Root, fixture: &Path) -> Oracle {
    let repository = root.join("repository");
    let source = tree(&repository.join("project"));
    git(&["init", "--quiet"], &repository);
    git(&["add", "-A"], &repository);
    git(&["commit", "--quiet", "-m", "base"], &repository);
    let plain = tree(&root.join("plain"));
    let tools = tools(&root.0, fixture);
    Oracle {
        source,
        plain,
        tools,
    }
}

fn composition(root: &Root, setup: &Oracle, loss: &Arc<Loss>) -> WorkspaceComposition {
    WorkspaceComposition::with_profiles(
        profiles(&setup.source, &setup.plain, &setup.tools),
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap()
    .with_tool_dispatch(Box::new(LosingDispatch(Arc::clone(loss))))
}

#[test]
fn the_rust_runtime_answers_the_recorded_checkpoints_and_sweeps() {
    let _held = exclusive();
    let fixture = support::fixture("workspace-checkpoint-oracle");
    let provenance = support::document(&fixture, "provenance.json");
    for (name, digest) in provenance["files"].as_object().unwrap() {
        assert_eq!(
            sha256_hex(&fs::read(fixture.join(name)).unwrap()),
            digest.as_str().unwrap(),
            "{name} is the recorded file"
        );
    }
    let root = Root::fixed();
    let setup = oracle(&root, &fixture);
    let loss = Arc::new(Loss::default());
    let workspace = composition(&root, &setup, &loss);
    let owners = Owners::new(root, workspace);
    let frames: Vec<Value> = fs::read_to_string(fixture.join("frames.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(frames.len(), 58);
    let copies = owners.root.join("evolution-workspaces");
    let mut jobs: BTreeMap<String, String> = BTreeMap::new();
    let mut parked: BTreeMap<String, Value> = BTreeMap::new();
    for (index, frame) in frames.iter().enumerate() {
        let method = frame["method"].as_str().unwrap();
        let params = &frame["params"];
        let label = request_id(params)
            .or_else(|| {
                let job = params["jobId"].as_str()?;
                jobs.iter()
                    .find(|(_, id)| id.as_str() == job)
                    .map(|(label, _)| label.clone())
            })
            .unwrap_or_default();
        // The oracle's own edits between frames: the source edited before
        // the second checkpoint and again before the lost one, and two
        // strangers placed among the copies before the first sweep.
        if method == "job.submit" && label == "request-checkpoint" {
            write_source(
                &setup.source.join(INDEX),
                &format!("{INDEX_SOURCE}// edited\n"),
            );
        }
        if method == "job.submit" && label == "request-checkpoint-lost" {
            write_source(
                &setup.source.join(INDEX),
                &format!("{INDEX_SOURCE}// edited again\n"),
            );
        }
        if method == "job.plan" && label == "request-sweep-dry" {
            for stranger in ["evo-stranger", "not-a-copy"] {
                fs::create_dir_all(copies.join(stranger).join("workspace")).unwrap();
                fs::write(
                    copies.join(stranger).join("workspace/kept.txt"),
                    "stranger\n",
                )
                .unwrap();
            }
        }
        let answer = match method {
            "job.plan" => support::legacy_plan_answer(owners.plan(params)),
            "job.submit" => {
                let answer = owners.submit(params);
                if let Some(job) = answer["result"]["jobId"].as_str() {
                    jobs.insert(label.clone(), job.to_owned());
                }
                answer
            }
            "job.run" => {
                let job = params["jobId"].as_str().unwrap();
                let first = !parked.contains_key(job);
                loss.lost
                    .store(label.ends_with("-lost") && first, Ordering::SeqCst);
                let answer = owners.run(job);
                loss.lost.store(false, Ordering::SeqCst);
                if answer["result"]["state"] == "waitingForRecovery" {
                    parked.insert(job.to_owned(), owners.record(job));
                }
                answer
            }
            "job.reconcile" => owners.reconcile(params["jobId"].as_str().unwrap()),
            "job.result" => owners.result(params["jobId"].as_str().unwrap()),
            other => panic!("the oracle records no {other}"),
        };
        // Every answer is one the published method schemas admit (a plan's
        // is checked where its review digest is set aside).
        if method != "job.plan" {
            support::hdc_oracle::assert_conforms(method, &answer);
        }
        let mut recorded = json!({"ok": frame["ok"]});
        if frame["ok"] == true {
            recorded["result"] = frame["result"].clone();
        } else {
            recorded["error"] = frame["error"].clone();
        }
        assert_eq!(answer, recorded, "frame {index}: {method} {label}");
    }
    // Every checkpoint and read that reached its dispatch started one child,
    // every sweep ran once; the two parked Jobs were never run again.
    assert_eq!(loss.started.load(Ordering::SeqCst), 6);
    assert_eq!(loss.swept.load(Ordering::SeqCst), 6);
    // What the Runtime keeps afterwards, byte for byte: the capability store
    // — each checkpoint's one-use capability for its exact plan, its
    // generations and its uses — ...
    assert_eq!(
        files(&owners.root.join("jobs-state/capabilities")),
        files(&fixture.join("capabilities"))
    );
    // ... the published products ...
    for job in fs::read_dir(fixture.join("artifacts")).unwrap() {
        let job = job.unwrap().file_name();
        assert_eq!(
            files(&owners.root.join("artifacts").join(&job))
                .into_iter()
                .filter(|(name, _)| name.starts_with("ART-"))
                .collect::<Vec<_>>(),
            files(&fixture.join("artifacts").join(&job)),
            "{job:?}'s published products"
        );
    }
    // ... the sealed archive the Runtime owns ...
    assert_eq!(
        files(&owners.root.join("workspace-patch-attempts"))
            .into_iter()
            .filter(|(name, _)| name.starts_with("checkpoint-"))
            .collect::<Vec<_>>(),
        files(&fixture.join("attempts"))
    );
    // ... the copies' audit records, and what each entry of their root still
    // holds: the strangers untouched ...
    let mut inventory = Map::new();
    for name in names(&copies) {
        inventory.insert(name.clone(), json!(names(&copies.join(&name))));
        for record in ["workspace.json", "teardown.json"] {
            let path = copies.join(&name).join(record);
            if path.exists() {
                assert_eq!(
                    fs::read(&path).unwrap(),
                    fs::read(fixture.join("copies").join(&name).join(record)).unwrap(),
                    "{name}/{record}"
                );
            }
        }
    }
    assert_eq!(
        Value::Object(inventory),
        support::document(&fixture, "copies/inventory.json")
    );
    assert_eq!(
        fs::read(copies.join("evo-stranger/workspace/kept.txt")).unwrap(),
        b"stranger\n"
    );
    // ... and the parked Jobs' durable records: the exact typed action each
    // persisted before its intent, the use a checkpoint consumed, its story.
    for (name, label) in [
        ("parked-sweep-record.json", "request-sweep-lost"),
        ("parked-checkpoint-record.json", "request-checkpoint-lost"),
    ] {
        let recorded = support::document(&fixture, name);
        let job = &jobs[label];
        assert_eq!(recorded["jobID"], json!(job));
        assert_eq!(parked[job.as_str()], recorded, "{name}");
    }
}

const CHECKPOINT: &str = "workspace.create-checkpoint";
const SWEEP: &str = "workspace.sweep-isolated-copies";

/// The timeline of one Job, as its record keeps it.
fn timeline(owners: &Owners, job: &str) -> Vec<String> {
    owners.record(job)["timeline"]
        .as_array()
        .unwrap()
        .iter()
        .map(|line| line.as_str().unwrap().to_owned())
        .collect()
}

/// A checkpoint tool whose bytes changed after its profile pinned them is
/// never run: the fresh action refuses before any intent — the whole profile
/// is re-measured — and a plan names the drift. The capability issued at
/// admission is never consumed.
#[test]
fn a_checkpoint_tool_that_changed_after_its_pin_is_never_run() {
    let fixture = support::fixture("workspace-checkpoint-oracle");
    for (drifted, inputs, planned) in [
        (
            "git",
            json!({"projectRef": PROJECT}),
            // The archive project is untouched, so only the named profile
            // refuses.
            "typed plan preflight failed before authorization: workspace.toolIdentityDrift",
        ),
        (
            "bsdtar",
            json!({"projectRef": ARCHIVE_PROJECT, "checkpointFilePaths": [INDEX]}),
            // Both profiles pin the archive writer: none can serve it.
            "workspace.create-checkpoint@1 is runtime unavailable: workspace.toolIdentityDrift",
        ),
    ] {
        let root = Root::temporary("drift");
        let setup = oracle(&root, &fixture);
        write_source(
            &setup.source.join(INDEX),
            &format!("{INDEX_SOURCE}// edited\n"),
        );
        let loss = Arc::new(Loss::default());
        let workspace = composition(&root, &setup, &loss);
        let owners = Owners::new(root, workspace);
        let accepted = owners.submit(&request("drift", CHECKPOINT, inputs.clone(), None));
        let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
        // The same name now runs other bytes, which would leave a mark.
        let marker = owners.root.join("ran");
        let tool = owners.root.join("tools").join(drifted);
        fs::write(
            &tool,
            format!("#!/bin/sh\n/usr/bin/touch {}\n", text(&marker)),
        )
        .unwrap();
        chmod(&tool, 0o755);
        let ran = owners.run(&job);
        assert_eq!(ran["result"]["state"], "failed", "{drifted}: {ran}");
        assert!(!marker.exists(), "{drifted}: the changed tool never ran");
        assert_eq!(loss.started.load(Ordering::SeqCst), 0, "{drifted}");
        let story = timeline(&owners, &job);
        assert!(
            !story.iter().any(|line| line.starts_with("intent ")),
            "{drifted}: no intent: {story:?}"
        );
        assert!(
            story
                .iter()
                .any(|line| line.contains("workspace.toolIdentityDrift")),
            "{drifted}: {story:?}"
        );
        assert!(
            owners.record(&job).get("admissionEvidence").is_none() || {
                owners.record(&job)["admissionEvidence"]["kind"] != "runtimeCapability"
            }
        );
        let plan = owners.plan(&request("drifted", CHECKPOINT, inputs, None));
        assert_eq!(
            plan,
            refused("invalidInput", planned, Some(proven())),
            "{drifted}"
        );
    }
}

/// A checkpoint's tool is opened by the digest its profile pinned when it is
/// started: bytes swapped in after the step was lowered — between the plan
/// and the spawn — are refused there, and nothing runs.
#[test]
fn a_checkpoint_tool_swapped_at_its_dispatch_is_refused_there() {
    struct Swapping {
        tool: PathBuf,
        marker: PathBuf,
    }
    impl WorkspaceToolDispatch for Swapping {
        fn dispatch(&self, invocation: &ToolInvocation<'_>) -> Result<ToolReceipt, ToolFailure> {
            fs::write(
                &self.tool,
                format!("#!/bin/sh\n/usr/bin/touch {}\n", self.marker.display()),
            )
            .unwrap();
            VerifiedToolDispatch.dispatch(invocation)
        }
    }
    let fixture = support::fixture("workspace-checkpoint-oracle");
    let root = Root::temporary("swap");
    let setup = oracle(&root, &fixture);
    write_source(
        &setup.source.join(INDEX),
        &format!("{INDEX_SOURCE}// edited\n"),
    );
    let marker = root.join("swapped-tool-ran");
    let workspace = WorkspaceComposition::with_profiles(
        profiles(&setup.source, &setup.plain, &setup.tools),
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap()
    .with_tool_dispatch(Box::new(Swapping {
        tool: setup.tools.git.clone(),
        marker: marker.clone(),
    }));
    let owners = Owners::new(root, workspace);
    let accepted = owners.submit(&request(
        "swap",
        CHECKPOINT,
        json!({"projectRef": PROJECT}),
        None,
    ));
    let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
    let ran = owners.run(&job);
    assert_eq!(ran["result"]["state"], "failed", "{ran}");
    assert!(!marker.exists(), "the swapped tool never ran");
    let story = timeline(&owners, &job);
    assert!(
        story.contains(&"failed create-checkpoint".to_owned()),
        "{story:?}"
    );
    assert!(
        story.iter().any(|line| line.contains("dispatch refused: ")),
        "{story:?}"
    );
    // The use the Job consumed is settled: its dispatch was refused.
    assert_eq!(
        owners.record(&job)["admissionEvidence"]["kind"],
        "runtimeCapability"
    );
}

/// Foundation's spelling of a canonical root, which a profile keeps.
fn text_foundation(path: &Path) -> String {
    let physical = text(path);
    match physical.strip_prefix("/private") {
        Some(rest) if Path::new(rest).exists() => rest.to_owned(),
        _ => physical,
    }
}

/// A checkpoint's policy is the Runtime's own: no capability a caller names
/// admits one — not one the store does not hold, and not a person's grant
/// the store does hold for exactly this tree, operation and plan — and
/// nothing is admitted or started. The Runtime's own capability admits one
/// use of the exact plan.
#[test]
fn no_capability_a_caller_names_admits_a_checkpoint() {
    let fixture = support::fixture("workspace-checkpoint-oracle");
    let root = Root::temporary("named");
    let setup = oracle(&root, &fixture);
    let loss = Arc::new(Loss::default());
    let workspace = composition(&root, &setup, &loss);
    let owners = Owners::new(root, workspace);
    let inputs = json!({"projectRef": PROJECT});
    let planned = owners.plan(&request("probe", CHECKPOINT, inputs.clone(), None));
    let plan_digest = planned["result"]["materializedPlanDigest"]
        .as_str()
        .unwrap()
        .to_owned();
    let identity = sha256_hex(
        format!(
            "arkdeck-workspace|{PROFILE}|{}",
            text_foundation(&setup.source)
        )
        .as_bytes(),
    );
    let grant = arkdeck_hoststore::RuntimeCapability::from_value(&json!({
        "capabilityID": "CAP-RT-PERSON-ISSUED-CHECKPOINT",
        "targetScope": {"kind": "workspaceIdentity", "sha256": identity,
            "expectedWorkspaceRevision": "", "allowedFileScopesDigest": sha256_hex(SCOPE.as_bytes())},
        "operationScope": [{"operationID": CHECKPOINT, "version": 1}],
        "effectCeiling": "deviceMutation",
        "inputConstraints": {},
        "issuedAtUTC": "2026-09-24T00:00:00Z", "expiresAtUTC": "2026-10-24T00:00:00Z",
        "maximumUses": 10,
        "issuer": {"kind": "maintainerMergedPR", "reference": "pr:0"},
        "revocation": {"state": "active"},
        "exactPlanDigest": plan_digest,
    }))
    .unwrap();
    owners.capabilities.install(&grant).unwrap();
    for (label, capability) in [
        ("granted", "CAP-RT-PERSON-ISSUED-CHECKPOINT"),
        ("unknown", "CAP-RT-NOT-IN-THE-STORE"),
    ] {
        for project in [PROJECT, ARCHIVE_PROJECT] {
            let inputs = if project == PROJECT {
                json!({"projectRef": PROJECT})
            } else {
                json!({"projectRef": ARCHIVE_PROJECT, "checkpointFilePaths": [INDEX]})
            };
            let answer = owners.submit(&request(label, CHECKPOINT, inputs, Some(capability)));
            assert_eq!(
                answer,
                refused(
                    "admissionDenied",
                    "caller-supplied capabilities cannot admit a Runtime-owned policy",
                    Some(proven())
                ),
                "{label} {project}"
            );
        }
    }
    let admitted = fs::read_dir(owners.root.join("jobs-state/jobs"))
        .map(|entries| entries.count())
        .unwrap_or(0);
    assert_eq!(admitted, 0, "nothing admitted");
    // The Runtime's own: one use, pinned to the exact plan, for this tree.
    let accepted = owners.submit(&request("own", CHECKPOINT, inputs, None));
    let job = accepted["result"]["jobId"].as_str().unwrap();
    let capability = owners.record(job)["request"]["authorization"]["capabilityId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        capability.starts_with("CAP-RT-POLICY-") && capability.ends_with("-G1"),
        "{capability}"
    );
    let status = owners
        .capabilities
        .handle(
            "capability.inspect",
            json!({"capabilityId": capability}).as_object().unwrap(),
        )
        .unwrap();
    assert_eq!(status["capability"]["maximumUses"], 1, "{status}");
    assert_eq!(
        status["capability"]["exactPlanDigest"], plan_digest,
        "{status}"
    );
    assert_eq!(
        status["capability"]["targetScope"]["sha256"], identity,
        "{status}"
    );
    assert_eq!(
        status["capability"]["issuer"]["kind"], "runtimeDefaultPolicy",
        "{status}"
    );
    assert_eq!(loss.started.load(Ordering::SeqCst), 0);
}

/// The revision Swift's provider measures over the oracle profile's files
/// in a tree that is not a git checkout.
fn revision(files: &[(&str, &str)]) -> String {
    let mut material = format!("profileVersion\t{PROFILE}\nhead\tabsent\nindex\tabsent\n");
    for (path, contents) in files {
        material.push_str(&format!(
            "file\t{path}\t{}\n",
            sha256_hex(contents.as_bytes())
        ));
    }
    sha256_hex(material.as_bytes())
}

/// A sweep destroys only what the Runtime can vouch for: a copy whose tree
/// moved from its base — with no durable patch lineage deriving what it now
/// holds — is not attested, is kept as unknown with its tree and without a
/// teardown, and its derived profile still resolves; the quiescent copy the
/// Runtime vouches for is destroyed.
#[test]
fn a_copy_the_runtime_cannot_vouch_for_is_never_swept() {
    let fixture = support::fixture("workspace-checkpoint-oracle");
    let root = Root::temporary("vouch");
    let setup = oracle(&root, &fixture);
    let loss = Arc::new(Loss::default());
    let workspace = composition(&root, &setup, &loss);
    let owners = Owners::new(root, workspace);
    // Two copies of the plain project, each made by its own Job.
    let source_revision = revision(&[(ABILITY, ABILITY_SOURCE), (INDEX, INDEX_SOURCE)]);
    let mut made = BTreeMap::new();
    for (label, scope) in [
        ("tampered", "entry/src/main/ets/pages/**"),
        ("quiescent", "entry/src/main/ets/entryability/**"),
    ] {
        let accepted = owners.submit(&request(
            label,
            "workspace.prepare-isolated-copy",
            json!({"projectRef": ARCHIVE_PROJECT, "allowedFileGlobs": [scope],
                "expectedWorkspaceRevision": source_revision}),
            None,
        ));
        let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
        assert_eq!(owners.run(&job)["result"]["state"], "succeeded");
        made.insert(format!("runtime-{job}"), label);
    }
    let copies = owners.root.join("evolution-workspaces");
    let mut roots = BTreeMap::new();
    for name in names(&copies) {
        let manifest: Value =
            serde_json::from_slice(&fs::read(copies.join(&name).join("workspace.json")).unwrap())
                .unwrap();
        let owner = manifest["workspace"]["htaskID"].as_str().unwrap();
        roots.insert(
            made[owner],
            (name, manifest["workspace"]["projectRef"].clone()),
        );
    }
    let (tampered, tampered_ref) = roots["tampered"].clone();
    let (quiescent, quiescent_ref) = roots["quiescent"].clone();
    // The tampered copy's tree moves inside its own scope.
    let edited = copies.join(&tampered).join("workspace").join(INDEX);
    fs::write(&edited, "tampered\n").unwrap();
    let swept = owners.submit(&request(
        "sweep",
        SWEEP,
        json!({"retainLatestCount": 0, "minimumQuiescentSeconds": 0, "dryRun": false}),
        None,
    ));
    let job = swept["result"]["jobId"].as_str().unwrap().to_owned();
    assert_eq!(owners.run(&job)["result"]["state"], "succeeded");
    let product = files(&owners.root.join("artifacts").join(&job))
        .into_iter()
        .find(|(name, _)| name.starts_with("ART-"))
        .unwrap()
        .1;
    let findings: Value = serde_json::from_slice(&product).unwrap();
    let dispositions: BTreeMap<String, String> = findings["findings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|finding| {
            (
                finding["workspaceId"].as_str().unwrap().to_owned(),
                finding["disposition"].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    assert_eq!(
        dispositions,
        BTreeMap::from([
            (tampered.clone(), "unknownTaskRetained".to_owned()),
            (quiescent.clone(), "destroyed".to_owned()),
        ])
    );
    assert_eq!(fs::read(&edited).unwrap(), b"tampered\n");
    assert!(!copies.join(&tampered).join("teardown.json").exists());
    assert!(!copies.join(&quiescent).join("workspace").exists());
    assert!(copies.join(&quiescent).join("teardown.json").exists());
    // The unattested copy still resolves; the destroyed one does not.
    let checkpoint = |label: &str, project: &Value, path: &str| {
        owners.plan(&request(
            label,
            CHECKPOINT,
            json!({"projectRef": project, "checkpointFilePaths": [path]}),
            None,
        ))
    };
    let kept = checkpoint("kept", &tampered_ref, INDEX);
    assert_eq!(kept["ok"], true, "{kept}");
    assert_eq!(
        checkpoint("destroyed", &quiescent_ref, ABILITY),
        refused(
            "invalidInput",
            &format!(
                "typed plan preflight failed before authorization: \
                 workspace.projectProfileUnavailable:{}",
                quiescent_ref.as_str().unwrap()
            ),
            Some(proven())
        )
    );
}

/// The host's own tools checkpoint a production-shaped project in the
/// Runtime's clean base environment: `/usr/bin/git` writes a commit object
/// and leaves the working copy, its index and its stash list as they were;
/// `/usr/bin/bsdtar` seals the declared files into the Runtime-owned
/// archive.
#[test]
fn the_host_tools_checkpoint_a_production_shaped_project() {
    let root = Root::temporary("host");
    let repository = root.join("repository");
    let source = tree(&repository.join("project"));
    git(&["init", "--quiet"], &repository);
    git(&["add", "-A"], &repository);
    git(&["commit", "--quiet", "-m", "base"], &repository);
    let plain = tree(&root.join("plain"));
    write_source(&source.join(INDEX), &format!("{INDEX_SOURCE}// edited\n"));
    let host = |id: &str, path: &str| WorkspaceCommandPreset::hashing(id, path, None, &[], 120);
    let checkout = WorkspaceProfile::primary(
        PROFILE,
        PROJECT,
        &text(&source),
        &[SCOPE],
        host("source-inspection", "/usr/bin/grep").unwrap(),
        host("unified-diff", "/usr/bin/patch").unwrap(),
        ProfilePresets {
            source_control: Some(host("git", "/usr/bin/git").unwrap()),
            ..ProfilePresets::default()
        },
    )
    .unwrap();
    let archive = WorkspaceProfile::primary(
        PROFILE,
        ARCHIVE_PROJECT,
        &text(&plain),
        &[SCOPE],
        host("source-inspection", "/usr/bin/grep").unwrap(),
        host("unified-diff", "/usr/bin/patch").unwrap(),
        ProfilePresets {
            archive_checkpoint: Some(host("sealed-source-archive", "/usr/bin/bsdtar").unwrap()),
            ..ProfilePresets::default()
        },
    )
    .unwrap();
    let workspace = WorkspaceComposition::with_profiles(
        vec![archive, checkout],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap();
    let owners = Owners::new(root, workspace);
    let status_before = git(&["status", "--porcelain=v1"], &repository);
    let index_before = fs::read(repository.join(".git/index")).unwrap();
    let mut envelopes = BTreeMap::new();
    for (label, inputs) in [
        ("git", json!({"projectRef": PROJECT})),
        (
            "archive",
            json!({"projectRef": ARCHIVE_PROJECT, "checkpointFilePaths": [INDEX, ABILITY]}),
        ),
    ] {
        let accepted = owners.submit(&request(label, CHECKPOINT, inputs, None));
        let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
        let ran = owners.run(&job);
        assert_eq!(ran["result"]["state"], "succeeded", "{label}: {ran}");
        let product = files(&owners.root.join("artifacts").join(&job))
            .into_iter()
            .find(|(name, _)| name.starts_with("ART-"))
            .unwrap()
            .1;
        envelopes.insert(
            label,
            (job, serde_json::from_slice::<Value>(&product).unwrap()),
        );
    }
    let (_, checkpoint) = &envelopes["git"];
    assert_eq!(checkpoint["checkpointKind"], "gitObject");
    let object = checkpoint["checkpointObject"].as_str().unwrap();
    assert_eq!(git(&["cat-file", "-t", object], &repository), b"commit\n");
    // The object moved no ref, no index entry and no working file.
    assert_eq!(git(&["stash", "list"], &repository), b"");
    assert_eq!(
        git(&["status", "--porcelain=v1"], &repository),
        status_before
    );
    assert_eq!(
        fs::read(repository.join(".git/index")).unwrap(),
        index_before
    );
    let (job, sealed) = &envelopes["archive"];
    assert_eq!(sealed["checkpointKind"], "sealedArchive");
    let archive = owners
        .root
        .join("workspace-patch-attempts")
        .join(format!("checkpoint-{}.tar", sha256_hex(job.as_bytes())));
    let bytes = fs::read(&archive).unwrap();
    assert_eq!(sealed["checkpointObject"], sha256_hex(&bytes));
    assert_eq!(sealed["checkpointByteCount"], bytes.len().to_string());
    let listed = Command::new("/usr/bin/bsdtar")
        .arg("-tf")
        .arg(&archive)
        .env_clear()
        .output()
        .unwrap()
        .stdout;
    let listed = String::from_utf8(listed).unwrap();
    for path in [INDEX, ABILITY] {
        assert!(listed.lines().any(|line| line == path), "{path}: {listed}");
    }
}

/// An archive checkpoint never writes over anything at its destination: a
/// file already at the path its Job derives refuses the fresh action before
/// any intent, the archive writer is never started, and the file is left as
/// it was.
#[test]
fn an_archive_checkpoint_never_writes_over_its_destination() {
    let fixture = support::fixture("workspace-checkpoint-oracle");
    let root = Root::temporary("occupied");
    let setup = oracle(&root, &fixture);
    let loss = Arc::new(Loss::default());
    let workspace = composition(&root, &setup, &loss);
    let owners = Owners::new(root, workspace);
    let accepted = owners.submit(&request(
        "occupied",
        CHECKPOINT,
        json!({"projectRef": ARCHIVE_PROJECT, "checkpointFilePaths": [INDEX]}),
        None,
    ));
    let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
    let destination = owners
        .root
        .join("workspace-patch-attempts")
        .join(format!("checkpoint-{}.tar", sha256_hex(job.as_bytes())));
    fs::write(&destination, "kept\n").unwrap();
    let ran = owners.run(&job);
    assert_eq!(ran["result"]["state"], "failed", "{ran}");
    assert_eq!(fs::read(&destination).unwrap(), b"kept\n");
    assert_eq!(loss.started.load(Ordering::SeqCst), 0);
    let story = timeline(&owners, &job);
    assert!(
        !story.iter().any(|line| line.starts_with("intent ")),
        "{story:?}"
    );
    assert!(
        story
            .iter()
            .any(|line| line.contains("workspace checkpoint destination already exists")),
        "{story:?}"
    );
}
