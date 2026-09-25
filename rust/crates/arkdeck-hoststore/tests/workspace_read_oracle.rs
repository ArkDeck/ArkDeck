//! Replays the Swift oracle of the four read-only workspace operations
//! (`rust/tests/fixtures/workspace-read-oracle`, recorded by
//! `WorkspaceReadOracleContractTests`) against the Rust planner, admitter,
//! runner, reconciler and result reader over the same fixed root, profiles,
//! registered roots, stand-in tools and clock: every answer must be Swift's
//! (the plan's additive review digest aside), and what the Runtime keeps
//! afterwards — the published products and the durable records of the two
//! Jobs whose receipt was lost — Swift's byte for byte.
//!
//! The same binary pins what the oracle cannot show: a pinned tool or the
//! configured inspector changed after admission is never run; and the reads
//! over a production-shaped profile run the host's own `/usr/bin` tools, in
//! the clean base environment, and publish exactly what those tools print.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, JobAdmitter, JobPlanner, JobReconciler,
    JobResultReader, JobRunner, JobStore, MutationAuthority, MutationExecution, ProfilePresets,
    ToolFailure, ToolInvocation, ToolReceipt, VerifiedToolDispatch, WorkspaceCommandPreset,
    WorkspaceComposition, WorkspaceInspector, WorkspaceProfile, WorkspaceToolDispatch,
};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use support::chmod;

/// The recording's fixed root: the profiles and the registered roots name
/// the source trees by path, and the inspection's argv ends with one.
const ROOT: &str = "/private/tmp/arkdeck-workspace-read-oracle";
const LOCK: &str = "/private/tmp/arkdeck-workspace-read-oracle.lock";
const TIMESTAMP: &str = "2026-09-25T00:00:00Z";
const PROJECT: &str = "ReadOracleProject";
const PLAIN: &str = "PlainOracleProject";
const PROFILE: &str = "workspace-read-oracle@1";
const SCOPE: &str = "entry/src/main/ets/**";
const INDEX: &str = "entry/src/main/ets/pages/Index.ets";
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

/// Whether the read dispatch hands its receipt back, as the Swift oracle's
/// receipt-losing dispatcher decides it, and how many children it started.
#[derive(Default)]
struct Loss {
    lost: AtomicBool,
    started: AtomicUsize,
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
            "arkdeck-workspace-read-{label}-{:x}",
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

/// One OpenHarmony-shaped project below `root`: two ArkTS sources in the
/// profile's scope and a build profile outside it.
fn tree(root: &Path, name: &str) -> PathBuf {
    let source = root.join(name);
    let ets = source.join("entry/src/main/ets");
    fs::create_dir_all(ets.join("entryability")).unwrap();
    fs::create_dir_all(ets.join("pages")).unwrap();
    fs::write(ets.join("entryability/EntryAbility.ets"), ABILITY_SOURCE).unwrap();
    fs::write(ets.join("pages/Index.ets"), INDEX_SOURCE).unwrap();
    fs::write(source.join("build-profile.json5"), "{}\n").unwrap();
    source.canonicalize().unwrap()
}

/// The host's git in the closed environment the stand-in gives it, with the
/// author and the clock fixed, as the Swift oracle runs it.
fn git(arguments: &[&str], directory: &Path) {
    let status = Command::new("/usr/bin/git")
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
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success(), "git {arguments:?}");
}

/// The fixture's stand-in tools, executable, beside the sources.
struct Tools {
    grep: PathBuf,
    sed: PathBuf,
    git: PathBuf,
}

fn tools(root: &Path, fixture: &Path) -> Tools {
    let directory = root.join("tools");
    fs::create_dir(&directory).unwrap();
    for name in ["grep", "sed", "git"] {
        fs::copy(fixture.join(format!("{name}.sh")), directory.join(name)).unwrap();
        chmod(&directory.join(name), 0o755);
    }
    let directory = directory.canonicalize().unwrap();
    Tools {
        grep: directory.join("grep"),
        sed: directory.join("sed"),
        git: directory.join("git"),
    }
}

fn preset(id: &str, tool: &Path) -> WorkspaceCommandPreset {
    WorkspaceCommandPreset::hashing(id, &text(tool), None, &[], 30).unwrap()
}

/// The oracle's two profiles: a git working copy with a source reader, and
/// a plain tree offering the inspection alone.
fn profiles(source: &Path, plain: &Path, tools: &Tools) -> Vec<WorkspaceProfile> {
    let read = WorkspaceProfile::primary(
        PROFILE,
        PROJECT,
        &text(source),
        &[SCOPE],
        preset("source-inspection", &tools.grep),
        preset("unified-diff", &tools.grep),
        ProfilePresets {
            source_control: Some(preset("git", &tools.git)),
            source_reader: Some(preset("source-range", &tools.sed)),
            ..ProfilePresets::default()
        },
    )
    .unwrap();
    let bare = WorkspaceProfile::primary(
        PROFILE,
        PLAIN,
        &text(plain),
        &[SCOPE],
        preset("source-inspection", &tools.grep),
        preset("unified-diff", &tools.grep),
        ProfilePresets::default(),
    )
    .unwrap();
    vec![bare, read]
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

/// The regular files of one directory whose names start with `prefix`.
fn files(directory: &Path, prefix: &str) -> Vec<(String, Vec<u8>)> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut found: Vec<(String, Vec<u8>)> = entries
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with(prefix)
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

/// The oracle's composition over `root`: the operations provider over both
/// profiles, the inspector and the registered roots behind it, the reads
/// dispatched through `loss`.
fn composition(
    root: &Root,
    profiles: Vec<WorkspaceProfile>,
    roots: BTreeMap<String, String>,
    inspector: &Path,
    dispatch: Box<dyn WorkspaceToolDispatch>,
) -> WorkspaceComposition {
    WorkspaceComposition::with_profiles(profiles, &root.join("evolution-workspaces"), oracle_now)
        .unwrap()
        .with_tool_dispatch(dispatch)
        .with_inspector(Some(WorkspaceInspector::hashing(&text(inspector)).unwrap()))
        .with_inspection_roots(roots)
}

fn request_id(params: &Value) -> Option<String> {
    let document: Value = serde_json::from_str(params["requestJson"].as_str()?).ok()?;
    document["requestId"].as_str().map(str::to_owned)
}

/// A typed request document for one read, as the Swift oracle writes it.
fn read_request(label: &str, operation: &str, inputs: Value) -> Value {
    let document = json!({
        "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
        "requestId": format!("request-{label}"),
        "idempotencyKey": format!("idempotency-{label}"),
        "target": {"targetId": "workspace-host"},
        "operation": {"id": operation, "version": 1},
        "inputs": inputs,
        "requestedOutputs": ["derivedArtifacts"],
    });
    json!({"requestJson": document.to_string()})
}

/// The oracle's fixed root with both trees, the working copy committed, and
/// the stand-in tools: its sources, profiles and registered roots.
struct Oracle {
    source: PathBuf,
    plain: PathBuf,
    tools: Tools,
}

fn oracle(root: &Root, fixture: &Path) -> Oracle {
    let source = tree(&root.0, "source");
    let plain = tree(&root.0, "plain");
    git(&["init", "--quiet"], &source);
    git(&["add", "-A"], &source);
    git(&["commit", "--quiet", "-m", "base"], &source);
    let tools = tools(&root.0, fixture);
    Oracle {
        source,
        plain,
        tools,
    }
}

impl Oracle {
    fn roots(&self) -> BTreeMap<String, String> {
        BTreeMap::from([
            (PROJECT.to_owned(), text(&self.source)),
            (PLAIN.to_owned(), text(&self.plain)),
        ])
    }
    fn profiles(&self) -> Vec<WorkspaceProfile> {
        profiles(&self.source, &self.plain, &self.tools)
    }
}

#[test]
fn the_rust_runtime_answers_the_recorded_reads() {
    let _held = exclusive();
    let fixture = support::fixture("workspace-read-oracle");
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
    let workspace = composition(
        &root,
        setup.profiles(),
        setup.roots(),
        &setup.tools.grep,
        Box::new(LosingDispatch(Arc::clone(&loss))),
    );
    let owners = Owners::new(root, workspace);
    let frames: Vec<Value> = fs::read_to_string(fixture.join("frames.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(frames.len(), 49);
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
        // Between the clean status and the dirty one the oracle edits a
        // source and adds another.
        if method == "job.submit" && label == "request-status-dirty" {
            fs::write(
                setup.source.join(INDEX),
                format!("{INDEX_SOURCE}// edited\n"),
            )
            .unwrap();
            fs::write(
                setup.source.join("entry/src/main/ets/pages/Added.ets"),
                "export const added = 1\n",
            )
            .unwrap();
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
        let mut recorded = json!({"ok": frame["ok"]});
        if frame["ok"] == true {
            recorded["result"] = frame["result"].clone();
        } else {
            recorded["error"] = frame["error"].clone();
        }
        assert_eq!(answer, recorded, "frame {index}: {method} {label}");
    }
    // Every read that reached its dispatch started one child; the two parked
    // reads were never started again.
    assert_eq!(loss.started.load(Ordering::SeqCst), 10);
    // What the Runtime keeps afterwards, byte for byte: the published
    // products, and nothing for a read that failed or was never confirmed.
    for job in jobs.values() {
        assert_eq!(
            files(&owners.root.join("artifacts").join(job), "ART-"),
            files(&fixture.join("artifacts").join(job), "ART-"),
            "{job}'s published products"
        );
    }
    // The parked Jobs' durable records are Swift's: the exact typed action
    // each persisted before its intent, and its story up to the park.
    for (name, label) in [
        ("parked-inspection-record.json", "request-inspect-lost"),
        ("parked-status-record.json", "request-status-lost"),
    ] {
        let recorded = support::document(&fixture, name);
        let job = &jobs[label];
        assert_eq!(recorded["jobID"], json!(job));
        assert_eq!(parked[job.as_str()], recorded, "{name}");
    }
}

/// A read planned against one tool is never run by another: a pinned tool
/// whose bytes changed after admission leaves its operation unavailable, so
/// the fresh action refuses before any intent; an inspector that changed
/// after the Runtime composed it is refused at its dispatch and never runs.
#[test]
fn a_tool_that_changed_after_admission_is_never_run() {
    let fixture = support::fixture("workspace-read-oracle");
    for drifted in ["git", "grep"] {
        let root = Root::temporary("drift");
        let setup = oracle(&root, &fixture);
        let loss = Arc::new(Loss::default());
        let workspace = composition(
            &root,
            setup.profiles(),
            setup.roots(),
            &setup.tools.grep,
            Box::new(LosingDispatch(Arc::clone(&loss))),
        );
        let owners = Owners::new(root, workspace);
        let (operation, inputs) = if drifted == "git" {
            (
                "workspace.inspect-git-status",
                json!({"projectRef": PROJECT}),
            )
        } else {
            (
                "workspace.inspect-source",
                json!({"projectRef": PLAIN, "symbol": "build", "fileScope": "*.ets"}),
            )
        };
        let accepted = owners.submit(&read_request("drift", operation, inputs));
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
        let record = owners.record(&job);
        let timeline: Vec<&str> = record["timeline"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .collect();
        if drifted == "git" {
            // The fresh action refuses before any intent: the tool is no
            // longer the one its profile pinned.
            assert_eq!(loss.started.load(Ordering::SeqCst), 0);
            assert!(
                timeline
                    .iter()
                    .any(|entry| entry.contains("workspace.toolIdentityDrift")),
                "{timeline:?}"
            );
            assert!(!timeline.iter().any(|entry| entry.starts_with("intent ")));
        } else {
            // The inspector is re-measured nowhere before its dispatch, which
            // opens it by the digest it was pinned by and refuses it.
            assert_eq!(loss.started.load(Ordering::SeqCst), 1);
            assert!(
                timeline.contains(&"failed inspect-workspace-source"),
                "{timeline:?}"
            );
        }
        assert!(files(&owners.root.join("artifacts").join(&job), "ART-").is_empty());
    }
}

/// Swift's admission asks the workspace dispatcher after the provider. With
/// every executable the start-up profiles pinned changed, the source
/// inspection — which its provider offers whenever an inspector and a
/// registered root exist — is refused at plan and at submit as Swift refuses
/// it; the other reads are refused by the provider first, as before.
#[test]
fn an_inspection_with_no_pinned_executable_left_is_refused_at_admission() {
    let fixture = support::fixture("workspace-read-oracle");
    let root = Root::temporary("dispatcher");
    let setup = oracle(&root, &fixture);
    let workspace = composition(
        &root,
        setup.profiles(),
        setup.roots(),
        &setup.tools.grep,
        Box::new(VerifiedToolDispatch),
    );
    let owners = Owners::new(root, workspace);
    let inspect = || {
        read_request(
            "dispatcher",
            "workspace.inspect-source",
            json!({"projectRef": PLAIN, "symbol": "build", "fileScope": "*.ets"}),
        )
    };
    assert_eq!(owners.plan(&inspect())["ok"], true);
    for tool in [&setup.tools.grep, &setup.tools.sed, &setup.tools.git] {
        let mut bytes = fs::read(tool).unwrap();
        bytes.extend_from_slice(b"# changed after its pin\n");
        fs::write(tool, bytes).unwrap();
    }
    let reason = "workspace.inspect-source@1 is runtime unavailable: provider executable is \
                  unavailable: failed(\"workspace registry has no available executable preset\")";
    for answer in [owners.plan(&inspect()), owners.submit(&inspect())] {
        assert_eq!(answer["ok"], false, "{answer}");
        assert_eq!(answer["error"]["code"], "invalidInput", "{answer}");
        assert_eq!(answer["error"]["message"], reason, "{answer}");
    }
    let status = owners.plan(&read_request(
        "dispatcher-status",
        "workspace.inspect-git-status",
        json!({"projectRef": PROJECT}),
    ));
    assert_eq!(
        status["error"]["message"],
        // The first start-up profile's reason, as Swift's provider answers
        // when none serves the read: the plain tree has no source control.
        "workspace.inspect-git-status@1 is runtime unavailable: workspace.presetUnavailable"
    );
}

/// The reads over a production-shaped profile run the host's own tools —
/// `/usr/bin/grep` as the inspector, `/usr/bin/sed`, `/usr/bin/git` — in the
/// clean base environment, and publish exactly what each prints when run
/// directly with the argv the provider builds.
#[test]
fn the_host_tools_answer_the_reads_as_they_answer_directly() {
    let root = Root::temporary("host");
    let source = tree(&root.0, "source");
    git(&["init", "--quiet"], &source);
    git(&["add", "-A"], &source);
    git(&["commit", "--quiet", "-m", "base"], &source);
    fs::write(source.join(INDEX), format!("{INDEX_SOURCE}// edited\n")).unwrap();
    let host = |id: &str, path: &str, timeout: i64| {
        WorkspaceCommandPreset::hashing(id, path, None, &[], timeout).unwrap()
    };
    let profile = WorkspaceProfile::primary(
        "waterflow-openharmony@1",
        "HostProject",
        &text(&source),
        &[SCOPE],
        host("source-inspection", "/usr/bin/grep", 30),
        host("unified-diff", "/usr/bin/patch", 120),
        ProfilePresets {
            source_control: Some(host("git", "/usr/bin/git", 120)),
            source_reader: Some(host("source-range", "/usr/bin/sed", 30)),
            ..ProfilePresets::default()
        },
    )
    .unwrap();
    let workspace = WorkspaceComposition::with_profiles(
        vec![profile],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap()
    .with_inspector(Some(WorkspaceInspector::hashing("/usr/bin/grep").unwrap()))
    .with_inspection_roots(BTreeMap::from([("HostProject".to_owned(), text(&source))]));
    let owners = Owners::new(root, workspace);
    let direct = |program: &str, arguments: &[&str]| {
        let output = Command::new(program)
            .args(arguments)
            .env_clear()
            .envs([("PATH", "/usr/bin:/bin"), ("LANG", "C"), ("LC_ALL", "C")])
            .output()
            .unwrap();
        output.stdout
    };
    let root_text = text(&source);
    // The canonical spelling the profile runs git and sed in.
    let profile_root = root_text
        .strip_prefix("/private")
        .unwrap_or(&root_text)
        .to_owned();
    for (label, operation, inputs, expected) in [
        (
            "inspect",
            "workspace.inspect-source",
            json!({"projectRef": "HostProject", "symbol": "build", "fileScope": "*.ets"}),
            direct(
                "/usr/bin/grep",
                &["-r", "-n", "--include", "*.ets", "--", "build", &root_text],
            ),
        ),
        (
            "range",
            "workspace.read-source-range",
            json!({"projectRef": "HostProject", "filePath": INDEX, "lineStart": 3, "lineEnd": 6}),
            direct(
                "/usr/bin/sed",
                &["-n", "3,6p", &format!("{profile_root}/{INDEX}")],
            ),
        ),
        (
            "status",
            "workspace.inspect-git-status",
            json!({"projectRef": "HostProject"}),
            direct(
                "/usr/bin/git",
                &[
                    "-C",
                    &profile_root,
                    "status",
                    "--porcelain=v1",
                    "--untracked-files=all",
                    "--",
                    ".",
                ],
            ),
        ),
        (
            "diff",
            "workspace.inspect-diff",
            json!({"projectRef": "HostProject", "baseRevision": "HEAD", "pathScope": "entry"}),
            direct(
                "/usr/bin/git",
                &["-C", &profile_root, "diff", "--stat", "HEAD", "--", "entry"],
            ),
        ),
    ] {
        assert!(!expected.is_empty(), "{label}: the host tool answers");
        let accepted = owners.submit(&read_request(label, operation, inputs));
        let job = accepted["result"]["jobId"]
            .as_str()
            .unwrap_or_else(|| panic!("{label}: {accepted}"))
            .to_owned();
        let ran = owners.run(&job);
        assert_eq!(ran["result"]["state"], "succeeded", "{label}: {ran}");
        let published = files(&owners.root.join("artifacts").join(&job), "ART-");
        assert_eq!(published.len(), 1, "{label}");
        assert_eq!(published[0].1, expected, "{label}");
    }
}
