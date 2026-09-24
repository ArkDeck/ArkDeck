//! Replays the Swift `workspace.build-openharmony@1` oracle
//! (`rust/tests/fixtures/workspace-build-oracle`, recorded by
//! `WorkspaceBuildOracleContractTests`) against the Rust planner, admitter,
//! runner, reconciler and result reader over the same fixed root, profile,
//! stand-in toolchain and clock: every answer must be Swift's (the plan's
//! additive review digest aside), and what the Runtime keeps afterwards —
//! the published build products, the capability store and the parked Job's
//! durable record — Swift's byte for byte.
//!
//! The same binary pins what the oracle cannot show: a toolchain whose Node
//! launcher or Hvigor script changed after admission is never run; a person's
//! primary tree is never built, not even under a standing grant a person
//! issued; and a registered Hvigor preset composes, through its resolved
//! DevEco pin, into the production-shaped profile of a registered project,
//! whose copy it builds — while a preset that did not resolve, or was
//! registered after the Runtime started, is refused before anything runs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, JobAdmitter, JobPlanner, JobReconciler,
    JobResultReader, JobRunner, JobStore, MutationAuthority, MutationExecution, ProfilePresets,
    ResolvedToolchain, ToolFailure, ToolInvocation, ToolReceipt, VerifiedResource,
    VerifiedToolDispatch, WorkspaceCommandPreset, WorkspaceComposition, WorkspaceProfile,
    WorkspaceProjectStore, WorkspaceToolDispatch, WorkspaceToolchainPinning,
};
use serde_json::{Map, Value, json};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use support::chmod;

/// The recording's fixed root: the profile pins the source tree, the tools
/// and the SDK root by path, and the lowered argv names the Hvigor script.
const ROOT: &str = "/private/tmp/arkdeck-workspace-build-oracle";
const LOCK: &str = "/private/tmp/arkdeck-workspace-build-oracle.lock";
const TIMESTAMP: &str = "2026-09-25T00:00:00Z";
const PROJECT: &str = "BuildOracleProject";
const PROFILE: &str = "workspace-build-oracle@1";
const DEBUG: &str = "oracle-debug";
const MISSING: &str = "oracle-missing-module";
const DEBUG_PRODUCT: &str = "entry/build/default/outputs/default/entry-default-unsigned.hap";
const LOST_AFTER: &str =
    "dispatch outcome unobservable: the oracle lost the receipt after the child ran";

fn oracle_now() -> Option<String> {
    Some(TIMESTAMP.into())
}

fn text(path: &Path) -> String {
    path.to_str().unwrap().to_owned()
}

/// Foundation's spelling of a physical path below `/private`, as Swift's
/// `standardizedFileURL` writes it: without `/private` where the rest names
/// the same file.
fn foundation(path: &Path) -> String {
    let text = text(path);
    match text.strip_prefix("/private") {
        Some(rest) if rest.starts_with('/') && Path::new(rest).exists() => rest.to_owned(),
        _ => text,
    }
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

/// Whether the build dispatch hands its receipt back, as the Swift oracle's
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
            "arkdeck-workspace-build-{label}-{:x}",
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

/// The oracle's OpenHarmony-shaped source tree below `root`: two ArkTS
/// sources in the profile's scope, the module manifest outside it.
fn source_tree(root: &Path) -> PathBuf {
    let source = root.join("source");
    let ets = source.join("entry/src/main/ets");
    fs::create_dir_all(ets.join("entryability")).unwrap();
    fs::create_dir_all(ets.join("pages")).unwrap();
    fs::write(
        ets.join("entryability/EntryAbility.ets"),
        "export default class EntryAbility {}\n",
    )
    .unwrap();
    fs::write(
        ets.join("pages/Index.ets"),
        "@Entry\n@Component\nstruct Index {\n  build() {}\n}\n",
    )
    .unwrap();
    fs::write(
        source.join("entry/src/main/module.json5"),
        "{ module: { name: 'entry' } }\n",
    )
    .unwrap();
    source.canonicalize().unwrap()
}

/// The stand-in toolchain beside the source: the Node launcher, its Hvigor
/// script and an SDK root, as the Swift oracle installed them.
struct Toolchain {
    node: PathBuf,
    hvigor: PathBuf,
    sdk: PathBuf,
}

fn toolchain(root: &Path, fixture: &Path) -> Toolchain {
    let tools = root.join("tools");
    fs::create_dir(&tools).unwrap();
    fs::create_dir(root.join("sdk")).unwrap();
    fs::copy(fixture.join("node.sh"), tools.join("node")).unwrap();
    fs::copy(fixture.join("hvigorw.js"), tools.join("hvigorw.js")).unwrap();
    chmod(&tools.join("node"), 0o755);
    chmod(&tools.join("hvigorw.js"), 0o644);
    Toolchain {
        node: tools.join("node"),
        hvigor: tools.join("hvigorw.js"),
        sdk: root.join("sdk"),
    }
}

/// A registered Hvigor preset's closed argv.
fn hvigor_arguments(script: &str, module: &str) -> Vec<String> {
    [
        script,
        "assembleHap",
        "--mode",
        "module",
        "-p",
        &format!("module={module}@default"),
        "-p",
        "product=default",
        "-p",
        "buildMode=debug",
        "--analyze=normal",
        "--parallel",
        "--incremental",
        "--no-daemon",
    ]
    .map(str::to_owned)
    .to_vec()
}

fn script_resource(tools: &Toolchain) -> VerifiedResource {
    let bytes = fs::read(&tools.hvigor).unwrap();
    VerifiedResource {
        path: foundation(&tools.hvigor),
        sha256: sha256_hex(&bytes),
        byte_count: bytes.len() as u64,
        require_executable: false,
    }
}

fn oracle_profile(source: &Path, tools: &Toolchain) -> WorkspaceProfile {
    oracle_profile_with(source, tools, Vec::new())
}

/// The oracle's profile, its presets pinning `extra` resources beside the
/// Hvigor script.
fn oracle_profile_with(
    source: &Path,
    tools: &Toolchain,
    extra: Vec<VerifiedResource>,
) -> WorkspaceProfile {
    let script = foundation(&tools.hvigor);
    let build = |id: &str, module: &str| {
        let arguments = hvigor_arguments(&script, module);
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        let mut resources = vec![script_resource(tools)];
        resources.extend(extra.iter().cloned());
        WorkspaceCommandPreset::hashing_with_resources(
            id,
            &text(&tools.node),
            None,
            &arguments,
            60,
            resources,
        )
        .unwrap()
    };
    WorkspaceProfile::primary(
        PROFILE,
        PROJECT,
        &text(source),
        &["entry/src/main/ets/**"],
        WorkspaceCommandPreset::hashing("inspect", "/usr/bin/grep", None, &[], 10).unwrap(),
        WorkspaceCommandPreset::hashing("patch", "/usr/bin/grep", None, &[], 10).unwrap(),
        ProfilePresets {
            build: vec![build(DEBUG, "entry"), build(MISSING, "broken")],
            build_products: [
                (DEBUG.to_owned(), DEBUG_PRODUCT.to_owned()),
                (
                    MISSING.to_owned(),
                    "broken/build/default/outputs/default/broken-default-unsigned.hap".to_owned(),
                ),
            ]
            .into(),
            ..ProfilePresets::default()
        },
    )
    .unwrap()
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
    let mut found: Vec<(String, Vec<u8>)> = fs::read_dir(directory)
        .unwrap()
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

/// How many copies below `evolution` hold a landed debug product.
fn landings(evolution: &Path) -> usize {
    fs::read_dir(evolution)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("evo-")
        })
        .filter(|path| path.join("workspace").join(DEBUG_PRODUCT).exists())
        .count()
}

/// The oracle's composition over `root`, its builds dispatched through
/// `loss`, the Node launcher's children given `DEVECO_SDK_HOME` as the
/// daemon names it.
fn composition(
    root: &Root,
    profile: &WorkspaceProfile,
    tools: &Toolchain,
    loss: &Arc<Loss>,
) -> WorkspaceComposition {
    WorkspaceComposition::with_profiles(
        vec![profile.clone()],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap()
    .with_tool_dispatch(Box::new(LosingDispatch(Arc::clone(loss))))
    .with_child_environment(
        &text(&tools.node),
        &[("DEVECO_SDK_HOME", &text(&tools.sdk))],
    )
}

fn request_id(params: &Value) -> Option<String> {
    let document: Value = serde_json::from_str(params["requestJson"].as_str()?).ok()?;
    document["requestId"].as_str().map(str::to_owned)
}

/// A typed request document for one build, as the Swift oracle writes it.
fn build_request(label: &str, project: &str, preset: &str, revision: Option<&str>) -> Value {
    let mut inputs = json!({"projectRef": project, "buildPresetRef": preset});
    if let Some(revision) = revision {
        inputs["expectedWorkspaceRevision"] = json!(revision);
    }
    let document = json!({
        "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
        "requestId": format!("request-{label}"),
        "idempotencyKey": format!("idempotency-{label}"),
        "target": {"targetId": "workspace-host"},
        "operation": {"id": "workspace.build-openharmony", "version": 1},
        "inputs": inputs,
        "requestedOutputs": ["derivedArtifacts"],
    });
    json!({"requestJson": document.to_string()})
}

/// A Runtime-owned copy of `project`'s whole scope, made through the
/// control plane: its reference and revision.
fn copy_of(
    owners: &Owners,
    project: &str,
    profile: &str,
    source: &Path,
    scope: &str,
) -> (String, String) {
    let revision = |root: &Path, profile: &str| {
        // The profile-scoped revision Swift's support computes, as the
        // isolation oracle measures it for this fixture's tree.
        let mut entries: Vec<(String, String)> = Vec::new();
        fn walk(root: &Path, directory: &Path, entries: &mut Vec<(String, String)>) {
            for entry in fs::read_dir(directory).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    walk(root, &path, entries);
                } else {
                    entries.push((
                        text(path.strip_prefix(root).unwrap()),
                        sha256_hex(&fs::read(&path).unwrap()),
                    ));
                }
            }
        }
        walk(root, &root.join("entry/src/main/ets"), &mut entries);
        entries.sort();
        let mut material = format!("profileVersion\t{profile}\nhead\tabsent\nindex\tabsent\n");
        for (path, digest) in entries {
            material.push_str(&format!("file\t{path}\t{digest}\n"));
        }
        sha256_hex(material.as_bytes())
    };
    let document = json!({
        "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
        "requestId": "request-copy", "idempotencyKey": "idempotency-copy",
        "target": {"targetId": "workspace-host"},
        "operation": {"id": "workspace.prepare-isolated-copy", "version": 1},
        "inputs": {"projectRef": project, "allowedFileGlobs": [scope],
            "expectedWorkspaceRevision": revision(source, profile)},
        "requestedOutputs": ["derivedArtifacts"],
    });
    let accepted = owners.submit(&json!({"requestJson": document.to_string()}));
    let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
    let copied = owners.run(&job);
    assert_eq!(copied["result"]["state"], "succeeded", "{copied}");
    let evolution = owners.root.join("evolution-workspaces");
    let workspace = fs::read_dir(&evolution)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .find(|name| name.starts_with("evo-"))
        .unwrap();
    let manifest: Value = serde_json::from_slice(
        &fs::read(evolution.join(&workspace).join("workspace.json")).unwrap(),
    )
    .unwrap();
    let copy_root = evolution.join(&workspace).join("workspace");
    (
        manifest["workspace"]["projectRef"]
            .as_str()
            .unwrap()
            .to_owned(),
        revision(&copy_root, profile),
    )
}

#[test]
fn the_rust_runtime_answers_the_recorded_build_sequence() {
    let _held = exclusive();
    let fixture = support::fixture("workspace-build-oracle");
    let provenance = support::document(&fixture, "provenance.json");
    for (name, digest) in provenance["files"].as_object().unwrap() {
        assert_eq!(
            sha256_hex(&fs::read(fixture.join(name)).unwrap()),
            digest.as_str().unwrap(),
            "{name} is the recorded file"
        );
    }
    let root = Root::fixed();
    let source = source_tree(&root.0);
    let tools = toolchain(&root.0, &fixture);
    let profile = oracle_profile(&source, &tools);
    let loss = Arc::new(Loss::default());
    let workspace = composition(&root, &profile, &tools, &loss);
    let owners = Owners::new(root, workspace);
    let frames: Vec<Value> = fs::read_to_string(fixture.join("frames.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(frames.len(), 22);
    let mut jobs: std::collections::BTreeMap<String, String> = Default::default();
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
                loss.lost
                    .store(label == "request-lost-after", Ordering::SeqCst);
                let answer = owners.run(params["jobId"].as_str().unwrap());
                loss.lost.store(false, Ordering::SeqCst);
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
        // The store owns the published product's bytes: its landing in the
        // copy does not outlive the publication.
        if method == "job.result" && label == "request-build" {
            assert_eq!(landings(&owners.root.join("evolution-workspaces")), 0);
        }
    }
    // The three builds that reached their dispatch each started one child;
    // the parked one was never started again.
    assert_eq!(loss.started.load(Ordering::SeqCst), 3);
    // What the Runtime keeps afterwards, byte for byte.
    assert_eq!(
        files(
            &owners.root.join("jobs-state/capabilities"),
            "runtime-capabilities"
        ),
        files(&fixture.join("capabilities"), "runtime-capabilities")
    );
    for job in fs::read_dir(fixture.join("artifacts")).unwrap() {
        let job = job.unwrap().file_name().into_string().unwrap();
        assert_eq!(
            files(&owners.root.join("artifacts").join(&job), "ART-"),
            files(&fixture.join("artifacts").join(&job), "ART-"),
            "{job}'s published products"
        );
    }
    // Nothing was built in the primary tree, and the copy keeps no product
    // the store now owns: the published product's landing is gone, while the
    // parked build's own, never published, is still there.
    assert!(!source.join("entry/build").exists());
    assert_eq!(
        landings(&owners.root.join("evolution-workspaces")),
        1,
        "the parked build's product stays where it landed, unpublished"
    );
    // The parked Job's durable record is Swift's: the exact typed action it
    // persisted before its intent, the use it consumed, its story.
    let parked = support::document(&fixture, "parked-record.json");
    let job = parked["jobID"].as_str().unwrap();
    assert_eq!(owners.record(job), parked);
}

/// A Node launcher or Hvigor script whose bytes changed after the Job was
/// admitted is never run, nor is one whose pinned executable resource lost
/// its execute permission: the Node change refuses the fresh plan before any
/// intent, the script's change and the resource's mode refuse the dispatch
/// itself. Nothing lands.
#[test]
fn a_toolchain_that_changed_after_admission_is_never_run() {
    let fixture = support::fixture("workspace-build-oracle");
    for drifted in ["node", "hvigorw.js", "ohpm"] {
        let root = Root::temporary("drift");
        let source = source_tree(&root.0);
        let tools = toolchain(&root.0, &fixture);
        // A pinned child tool the toolchain requires to be executable.
        let ohpm = root.join("tools/ohpm");
        fs::write(&ohpm, "#!/bin/sh\nexit 0\n").unwrap();
        chmod(&ohpm, 0o755);
        let bytes = fs::read(&ohpm).unwrap();
        let profile = oracle_profile_with(
            &source,
            &tools,
            vec![VerifiedResource {
                path: foundation(&ohpm),
                sha256: sha256_hex(&bytes),
                byte_count: bytes.len() as u64,
                require_executable: true,
            }],
        );
        let loss = Arc::new(Loss::default());
        let workspace = composition(&root, &profile, &tools, &loss);
        let owners = Owners::new(root, workspace);
        let (copy, revision) = copy_of(&owners, PROJECT, PROFILE, &source, "entry/src/main/ets/**");
        let accepted = owners.submit(&build_request("drift", &copy, DEBUG, Some(&revision)));
        let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
        let path = owners.root.join("tools").join(drifted);
        if drifted == "ohpm" {
            // The same bytes, no longer executable.
            chmod(&path, 0o644);
        } else {
            let mut bytes = fs::read(&path).unwrap();
            bytes.extend_from_slice(b"\n# changed after admission\n");
            fs::write(&path, bytes).unwrap();
        }
        let answer = owners.run(&job);
        assert_eq!(answer["result"]["state"], "failed", "{drifted}: {answer}");
        // The script's drift and the resource's mode are found by the
        // dispatch itself, which refuses before any child; the launcher's by
        // the fresh plan, before it.
        assert_eq!(
            loss.started.load(Ordering::SeqCst),
            usize::from(drifted != "node")
        );
        let record = owners.record(&job);
        let timeline = record["timeline"].as_array().unwrap();
        if drifted == "node" {
            // Refused at the fresh plan: no intent, no use consumed.
            assert!(
                !timeline
                    .iter()
                    .any(|line| line.as_str().unwrap().starts_with("intent ")),
                "{timeline:?}"
            );
        } else {
            // Refused by the dispatch: the intent's outcome is a failure, and
            // the reason is the resource.
            assert!(
                timeline.iter().any(|line| line == "failed build-project"),
                "{timeline:?}"
            );
            assert!(
                timeline.iter().any(|line| line
                    .as_str()
                    .unwrap()
                    .contains("dispatch resource identity refused")),
                "{timeline:?}"
            );
        }
        let copies = owners.root.join("evolution-workspaces");
        for entry in fs::read_dir(&copies).unwrap() {
            let entry = entry.unwrap().path();
            if entry
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("evo-")
            {
                assert!(!entry.join("workspace").join(DEBUG_PRODUCT).exists());
            }
        }
    }
}

/// A person's primary tree needs a standing capability a person issued. This
/// Runtime never issues one and never honours one, even when the store holds
/// a grant that would authorize the exact build: the submit is refused before
/// admission and nothing is built.
#[test]
fn a_primary_tree_is_never_built_even_under_a_person_issued_grant() {
    let fixture = support::fixture("workspace-build-oracle");
    let root = Root::temporary("primary");
    let source = source_tree(&root.0);
    let tools = toolchain(&root.0, &fixture);
    let profile = oracle_profile(&source, &tools);
    let loss = Arc::new(Loss::default());
    let workspace = composition(&root, &profile, &tools, &loss);
    let owners = Owners::new(root, workspace);
    let planned = owners.plan(&build_request("probe", PROJECT, DEBUG, None));
    assert_eq!(planned["ok"], true, "{planned}");
    let identity =
        sha256_hex(format!("arkdeck-workspace|{PROFILE}|{}", foundation(&source)).as_bytes());
    let grant = arkdeck_hoststore::RuntimeCapability::from_value(&json!({
        "capabilityID": "CAP-RT-PERSON-ISSUED-PRIMARY-TREE",
        "targetScope": {"kind": "workspaceIdentity", "sha256": identity,
            "expectedWorkspaceRevision": "",
            "allowedFileScopesDigest": sha256_hex(b"entry/src/main/ets/**")},
        "operationScope": [{"operationID": "workspace.build-openharmony", "version": 1}],
        "effectCeiling": "deviceMutation",
        "inputConstraints": {},
        "issuedAtUTC": "2026-09-24T00:00:00Z", "expiresAtUTC": "2026-10-24T00:00:00Z",
        "maximumUses": 10,
        "issuer": {"kind": "maintainerMergedPR", "reference": "pr:0"},
        "revocation": {"state": "active"},
    }))
    .unwrap();
    owners.capabilities.install(&grant).unwrap();
    let mut named = build_request("primary-granted", PROJECT, DEBUG, None);
    let mut document: Value = serde_json::from_str(named["requestJson"].as_str().unwrap()).unwrap();
    document["authorization"] = json!({"capabilityId": "CAP-RT-PERSON-ISSUED-PRIMARY-TREE"});
    named["requestJson"] = json!(document.to_string());
    for (request, message) in [
        (
            build_request("primary", PROJECT, DEBUG, None),
            "effect deviceMutation requires an explicit runtime capability".to_owned(),
        ),
        (
            named,
            "capability denied [denial:capabilityNotFound]: \
             capabilityNotFound(\"CAP-RT-PERSON-ISSUED-PRIMARY-TREE\")"
                .to_owned(),
        ),
    ] {
        let answer = owners.submit(&request);
        assert_eq!(answer["error"]["code"], "admissionDenied", "{answer}");
        assert_eq!(answer["error"]["message"], message);
    }
    assert_eq!(loss.started.load(Ordering::SeqCst), 0);
    assert!(!source.join("entry/build").exists());
}

/// A WaterFlow-shaped project registered with the Runtime, as
/// `waterFlowDemo` requires it.
fn registered_tree(base: &Path) -> PathBuf {
    let source = base.join("project");
    fs::create_dir_all(&source).unwrap();
    let source = source.canonicalize().unwrap();
    let ets = source.join("entry/src/main/ets");
    fs::create_dir_all(ets.join("pages")).unwrap();
    fs::write(ets.join("pages/Index.ets"), "struct Index {}\n").unwrap();
    fs::write(source.join("entry/src/main/module.json5"), "{}\n").unwrap();
    fs::write(source.join("build-profile.json5"), "{}\n").unwrap();
    source
}

/// The production composition over a registered project and its registered
/// Hvigor preset: the preset's exact DevEco pin resolved (here by a stand-in
/// resolver naming the fixture toolchain) into the profile, whose copy the
/// preset builds with the resolved SDK root in its environment. A preset the
/// resolver could not resolve, and one registered after the start, is
/// refused before anything runs.
#[test]
fn a_registered_hvigor_preset_composes_through_its_resolved_toolchain() {
    let fixture = support::fixture("workspace-build-oracle");
    let root = Root::temporary("registered");
    let tools = toolchain(&root.0, &fixture);
    let source = registered_tree(&root.0);
    fs::create_dir(root.join("workspace-projects")).unwrap();
    chmod(&root.join("workspace-projects"), 0o700);
    let pinning = || WorkspaceToolchainPinning {
        acquire: Box::new(|_, _, _| Ok(())),
        release: Box::new(|_, _| Ok(())),
    };
    let projects = Arc::new(
        WorkspaceProjectStore::open(&root.join("workspace-projects"))
            .unwrap()
            .with_dependency_pinning(Some(pinning()), None),
    );
    let call = |method: &str, params: Value| {
        projects
            .handle(
                method,
                params.as_object().unwrap(),
                &|| "2026-09-25T00:00:00.000Z".into(),
                &|_| Ok(()),
            )
            .unwrap()
    };
    let project = call(
        "workspace.project.register",
        json!({"registrationRequestId": "project", "kind": "openharmony", "root": text(&source)}),
    )["projectRef"]
        .as_str()
        .unwrap()
        .to_owned();
    let preset = |request: &str, digit: &str| {
        call(
            "workspace.preset.register",
            json!({"registrationRequestId": request, "projectRef": project, "kind": "build",
                "templateRef": "openharmony.hvigor-build@1", "timeoutSeconds": "600",
                "toolchainRef": format!("toolchain:sha256:{}", digit.repeat(64)),
                "toolchainGeneration": "1",
                "module": "entry", "product": "default", "buildMode": "debug"}),
        )["presetRef"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let resolvable = preset("resolvable", "a");
    let unresolvable = preset("unresolvable", "b");
    let resolved = Mutex::new(Vec::new());
    let resolver = |reference: &str, generation: u64, preset: &str| {
        resolved
            .lock()
            .unwrap()
            .push(format!("{reference} {generation} {preset}"));
        if reference.ends_with(&"a".repeat(64)) {
            Ok(ResolvedToolchain {
                node_path: text(&tools.node),
                hvigor_script_path: text(&tools.hvigor),
                sdk_root_path: text(&tools.sdk),
                verified_resources: vec![script_resource(&tools)],
            })
        } else {
            Err("resourceConflict: DevEco resolution requires an exact workspace-preset pin".into())
        }
    };
    let loss = Arc::new(Loss::default());
    let (workspace, unadopted) = WorkspaceComposition::compose(
        Arc::clone(&projects),
        &root.0,
        "/nonexistent-home",
        oracle_now,
        &resolver,
        None,
    )
    .unwrap();
    let unadopted = unadopted.unadopted;
    assert!(unadopted.is_empty());
    assert_eq!(
        resolved.lock().unwrap().len(),
        2,
        "both presets were resolved once"
    );
    let workspace = workspace.with_tool_dispatch(Box::new(LosingDispatch(Arc::clone(&loss))));
    let late = preset("late", "a");
    let owners = Owners::new(root, workspace);
    let (copy, revision) = copy_of(
        &owners,
        &project,
        "waterflow-openharmony@1",
        &source,
        "entry/src/main/ets/**",
    );
    // The unresolved preset and the late one are refused before admission.
    for (preset, label) in [(&unresolvable, "unresolvable"), (&late, "late")] {
        let answer = owners.submit(&build_request(label, &copy, preset, Some(&revision)));
        assert_eq!(
            answer["error"]["code"], "operationUnavailable",
            "{label}: {answer}"
        );
        assert_eq!(
            answer["error"]["message"],
            "workspace preset configuration changed; restart the Runtime before submitting a Job"
        );
    }
    let accepted = owners.submit(&build_request("build", &copy, &resolvable, Some(&revision)));
    let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
    let built = owners.run(&job);
    assert_eq!(built["result"]["state"], "succeeded", "{built}");
    assert_eq!(loss.started.load(Ordering::SeqCst), 1);
    let result = owners.result(&job);
    let artifacts = result["result"]["artifacts"].as_array().unwrap();
    let names: Vec<&str> = artifacts
        .iter()
        .map(|artifact| artifact["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["build.log", "unsigned.hap"]);
    let log = artifacts[0]["artifactId"].as_str().unwrap();
    let log = fs::read(owners.root.join("artifacts").join(&job).join(log)).unwrap();
    let log = String::from_utf8(log).unwrap();
    assert!(
        log.contains(&format!("DEVECO_SDK_HOME={}\n", text(&tools.sdk))),
        "{log}"
    );
    assert!(log.contains("BUILD SUCCESSFUL"), "{log}");
    // The registered project's own tree is never built.
    assert!(!source.join("entry/build").exists());
}
