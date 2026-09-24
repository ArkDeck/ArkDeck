//! Replays the Swift `workspace.apply-patch@1` / `workspace.revert-patch@1`
//! oracle (`rust/tests/fixtures/workspace-patch-oracle`, recorded by
//! `WorkspacePatchOracleContractTests`) against the Rust planner, admitter,
//! runner, reconciler and result reader over the same fixed root, profile,
//! stand-in patch tool and clock: every answer must be Swift's (the plan's
//! additive review digest aside), and what the Runtime keeps afterwards —
//! the durable patch attempts, the capability store, the copy's tree, the
//! copy's adoption at three points and the parked Job's durable record —
//! Swift's byte for byte.
//!
//! The same binary pins what the oracle cannot show: a person's primary tree
//! is never admitted, not even under a standing grant a person issued; a
//! patch tool whose bytes changed after the plan pinned them is never run;
//! a patch interrupted mid-run is parked by the restarted Runtime, answered
//! by a reconcile that reads back nothing and resends nothing, and never run
//! again; the real `/usr/bin/patch` applies and reverts through a
//! production-shaped profile; and two patch Jobs never run at once.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, JobAdmitter, JobPlanner, JobReconciler,
    JobResultReader, JobRunner, JobStore, MutationAuthority, MutationExecution, ProfilePresets,
    ToolFailure, ToolInvocation, ToolReceipt, VerifiedToolDispatch, WorkspaceCommandPreset,
    WorkspaceComposition, WorkspaceProfile, WorkspaceToolDispatch, recover_active_jobs,
};
use serde_json::{Map, Value, json};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use support::chmod;

/// The recording's fixed root: the profile pins the source tree by path and
/// the lowered argv names the copy and the patch Artifact by path.
const ROOT: &str = "/private/tmp/arkdeck-workspace-patch-oracle";
const LOCK: &str = "/private/tmp/arkdeck-workspace-patch-oracle.lock";
const TIMESTAMP: &str = "2026-09-20T00:00:00Z";
const PROJECT: &str = "PatchOracleProject";
const PROFILE: &str = "workspace-patch-oracle@1";
const LOST_BEFORE: &str =
    "dispatch outcome unobservable: the oracle lost the receipt before the child ran";
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

/// Whether the patch dispatch hands its receipt back, as the Swift oracle's
/// receipt-losing dispatcher decides it, and how many children it started.
#[derive(Default)]
struct Loss {
    mode: Mutex<&'static str>,
    started: AtomicUsize,
}

struct LosingDispatch(Arc<Loss>);

impl WorkspaceToolDispatch for LosingDispatch {
    fn dispatch(&self, invocation: &ToolInvocation<'_>) -> Result<ToolReceipt, ToolFailure> {
        let mode = *self.0.mode.lock().unwrap();
        if mode == "before" {
            return Err(ToolFailure::OutcomeUnknown(LOST_BEFORE.into()));
        }
        self.0.started.fetch_add(1, Ordering::SeqCst);
        let receipt = VerifiedToolDispatch.dispatch(invocation)?;
        if mode == "after" {
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
            "arkdeck-workspace-patch-{label}-{:x}",
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

/// The oracle's source tree, its stand-in patch tool and the input patches
/// published before its first request, each as Swift left them.
fn seed(root: &Root, fixture: &Path) -> PathBuf {
    let source = root.join("source");
    fs::create_dir_all(source.join("Sources")).unwrap();
    fs::write(source.join("Sources/App.txt"), "old\n").unwrap();
    fs::write(
        source.join("Sources/Other.txt"),
        "outside the narrowed scope\n",
    )
    .unwrap();
    fs::create_dir(root.join("tools")).unwrap();
    fs::copy(fixture.join("patch.sh"), root.join("tools/patch")).unwrap();
    chmod(&root.join("tools/patch"), 0o755);
    let inputs = root.join("artifacts/job-input-patch");
    fs::create_dir(&inputs).unwrap();
    chmod(&inputs, 0o700);
    for file in fs::read_dir(fixture.join("artifacts/job-input-patch")).unwrap() {
        let file = file.unwrap().path();
        let name = file.file_name().unwrap();
        fs::copy(&file, inputs.join(name)).unwrap();
        chmod(
            &inputs.join(name),
            if name == "index.json" { 0o600 } else { 0o400 },
        );
    }
    source.canonicalize().unwrap()
}

fn oracle_profile(source: &Path, tool: &Path) -> WorkspaceProfile {
    WorkspaceProfile::primary(
        PROFILE,
        PROJECT,
        &text(source),
        &["Sources/**"],
        WorkspaceCommandPreset::hashing("inspect", "/usr/bin/grep", None, &[], 10).unwrap(),
        WorkspaceCommandPreset::hashing("patch", &text(tool), None, &[], 10).unwrap(),
        ProfilePresets::default(),
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

/// Every regular file below `root`, tree-relative and sorted, with its
/// digest (the oracle's `tree(at:)`).
fn tree(root: &Path) -> Vec<Value> {
    fn walk(root: &Path, directory: &Path, entries: &mut Vec<(String, String)>) {
        for entry in fs::read_dir(directory).unwrap() {
            let path = entry.unwrap().path();
            let kind = fs::symlink_metadata(&path).unwrap().file_type();
            if kind.is_dir() {
                walk(root, &path, entries);
            } else if kind.is_file() {
                entries.push((
                    text(path.strip_prefix(root).unwrap()),
                    sha256_hex(&fs::read(&path).unwrap()),
                ));
            }
        }
    }
    let mut entries = Vec::new();
    walk(root, root, &mut entries);
    entries.sort();
    entries
        .into_iter()
        .map(|(path, sha256)| json!({"path": path, "sha256": sha256}))
        .collect()
}

/// The regular files of one directory, hidden ones aside, by name.
fn files(directory: &Path) -> Vec<(String, Vec<u8>)> {
    let mut found: Vec<(String, Vec<u8>)> = fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| !path.file_name().unwrap().to_string_lossy().starts_with('.'))
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

/// The oracle's composition over `root`, its patch steps dispatched through
/// `loss`.
fn composition(root: &Root, profile: &WorkspaceProfile, loss: &Arc<Loss>) -> WorkspaceComposition {
    WorkspaceComposition::with_profiles(
        vec![profile.clone()],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap()
    .with_tool_dispatch(Box::new(LosingDispatch(Arc::clone(loss))))
}

/// A restarted isolation manager's adoption over the same state.
fn adoption(root: &Path, profile: &WorkspaceProfile) -> Vec<String> {
    WorkspaceComposition::with_profiles(
        vec![profile.clone()],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap()
    .adopt_runtime_workspaces()
}

fn request_id(params: &Value) -> Option<String> {
    let document: Value = serde_json::from_str(params["requestJson"].as_str()?).ok()?;
    document["requestId"].as_str().map(str::to_owned)
}

#[test]
fn the_rust_runtime_answers_the_recorded_patch_sequence() {
    let _held = exclusive();
    let fixture = support::fixture("workspace-patch-oracle");
    let provenance = support::document(&fixture, "provenance.json");
    for (name, digest) in provenance["files"].as_object().unwrap() {
        assert_eq!(
            sha256_hex(&fs::read(fixture.join(name)).unwrap()),
            digest.as_str().unwrap(),
            "{name} is the recorded file"
        );
    }
    let root = Root::fixed();
    let source = seed(&root, &fixture);
    let profile = oracle_profile(&source, &root.join("tools/patch"));
    let loss = Arc::new(Loss::default());
    let workspace = composition(&root, &profile, &loss);
    let owners = Owners::new(root, workspace);
    let frames: Vec<Value> = fs::read_to_string(fixture.join("frames.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(frames.len(), 30);
    let mut jobs: std::collections::BTreeMap<String, String> = Default::default();
    let mut adoptions = json!({});
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
                let mode = match label.as_str() {
                    "request-lost-before" => "before",
                    "request-lost-after" => "after",
                    _ => "none",
                };
                *loss.mode.lock().unwrap() = mode;
                let answer = owners.run(params["jobId"].as_str().unwrap());
                *loss.mode.lock().unwrap() = "none";
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
        // The adoption a restarted isolation manager makes after the apply
        // and after the revert, as the oracle measured it.
        if method == "job.result" && label == "request-apply" {
            adoptions["afterApply"] = json!(adoption(&owners.root.0, &profile));
        }
        if method == "job.result" && label == "request-revert" {
            adoptions["afterRevert"] = json!(adoption(&owners.root.0, &profile));
        }
    }
    adoptions["final"] = json!(adoption(&owners.root.0, &profile));
    assert_eq!(adoptions, support::document(&fixture, "adoption.json"));
    // The lost-before receipt never started a child; every other patch Job
    // that reached its dispatch started exactly one.
    assert_eq!(loss.started.load(Ordering::SeqCst), 4);
    // What the Runtime keeps afterwards, byte for byte.
    assert_eq!(
        files(&owners.root.join("workspace-patch-attempts")),
        files(&fixture.join("attempts"))
    );
    assert_eq!(
        files(&owners.root.join("jobs-state/capabilities")),
        files(&fixture.join("capabilities"))
    );
    let recorded_tree = support::document(&fixture, "tree.json");
    let workspace_id = recorded_tree["workspaceID"].as_str().unwrap();
    assert_eq!(
        json!(tree(
            &owners
                .root
                .join("evolution-workspaces")
                .join(workspace_id)
                .join("workspace")
        )),
        recorded_tree["entries"]
    );
    // The primary tree is untouched.
    assert_eq!(fs::read(source.join("Sources/App.txt")).unwrap(), b"old\n");
    // The parked Job's durable record is Swift's: the exact typed action it
    // persisted before its intent, the use it consumed, its story.
    let parked = support::document(&fixture, "parked-record.json");
    let job = parked["jobID"].as_str().unwrap();
    assert_eq!(owners.record(job), parked);
}

/// A person's primary tree needs a standing capability a person issued. This
/// Runtime never issues one and never honours one, even when the store holds
/// a grant that would authorize the exact request: every such submit is
/// refused before admission and nothing reaches the tree. A Runtime-owned
/// copy of the same tree is issued its own capability.
#[test]
fn a_primary_tree_is_never_admitted_even_under_a_person_issued_grant() {
    let fixture = support::fixture("workspace-patch-oracle");
    let root = Root::temporary("primary");
    let source = seed(&root, &fixture);
    let profile = oracle_profile(&source, &root.join("tools/patch"));
    let loss = Arc::new(Loss::default());
    let workspace = composition(&root, &profile, &loss);
    let owners = Owners::new(root, workspace);
    let lease = "lease-v1:job-input-patch:ART-4ccb0a35050cacc5248ae8c1d2e9fb1c";
    let request = |label: &str, capability: Option<&str>| {
        let mut document = json!({
            "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
            "requestId": format!("request-{label}"),
            "idempotencyKey": format!("idempotency-{label}"),
            "target": {"targetId": "workspace-host"},
            "operation": {"id": "workspace.apply-patch", "version": 1},
            "inputs": {"projectRef": PROJECT, "patchArtifactRef": lease,
                "allowedFileGlobs": ["Sources/App.txt"]},
            "requestedOutputs": ["derivedArtifacts"],
        });
        if let Some(capability) = capability {
            document["authorization"] = json!({"capabilityId": capability});
        }
        json!({"requestJson": document.to_string()})
    };
    // The grant a maintainer's merged change would have installed for this
    // tree, its scopes and this exact request.
    let facts_plan = owners.plan(&request("probe", None));
    assert_eq!(facts_plan["ok"], true, "{facts_plan}");
    let identity =
        sha256_hex(format!("arkdeck-workspace|{PROFILE}|{}", text_foundation(&source)).as_bytes());
    let scopes = sha256_hex(b"Sources/**");
    let grant = arkdeck_hoststore::RuntimeCapability::from_value(&json!({
        "capabilityID": "CAP-RT-PERSON-ISSUED-PRIMARY-TREE",
        "targetScope": {"kind": "workspaceIdentity", "sha256": identity,
            "expectedWorkspaceRevision": "", "allowedFileScopesDigest": scopes},
        "operationScope": [{"operationID": "workspace.apply-patch", "version": 1}],
        "effectCeiling": "deviceMutation",
        "inputConstraints": {},
        "issuedAtUTC": "2026-09-19T00:00:00Z", "expiresAtUTC": "2026-10-19T00:00:00Z",
        "maximumUses": 10,
        "issuer": {"kind": "maintainerMergedPR", "reference": "pr:0"},
        "revocation": {"state": "active"},
    }))
    .unwrap();
    owners.capabilities.install(&grant).unwrap();
    for (label, capability, message) in [
        (
            "primary",
            None,
            "effect deviceMutation requires an explicit runtime capability".to_owned(),
        ),
        (
            "primary-granted",
            Some("CAP-RT-PERSON-ISSUED-PRIMARY-TREE"),
            "capability denied [denial:capabilityNotFound]: \
             capabilityNotFound(\"CAP-RT-PERSON-ISSUED-PRIMARY-TREE\")"
                .to_owned(),
        ),
    ] {
        let answer = owners.submit(&request(label, capability));
        assert_eq!(
            answer,
            refused("admissionDenied", &message, Some(proven())),
            "{label}"
        );
    }
    let admitted = fs::read_dir(owners.root.join("jobs-state/jobs"))
        .map(|entries| entries.count())
        .unwrap_or(0);
    assert_eq!(admitted, 0, "nothing admitted");
    assert_eq!(fs::read(source.join("Sources/App.txt")).unwrap(), b"old\n");
    assert_eq!(loss.started.load(Ordering::SeqCst), 0);
}

/// Foundation's spelling of a canonical root, which the profile keeps.
fn text_foundation(path: &Path) -> String {
    let physical = text(path);
    match physical.strip_prefix("/private") {
        Some(rest) if Path::new(rest).exists() => rest.to_owned(),
        _ => physical,
    }
}

/// A copy of the oracle project made by the Runtime, and its identities.
struct Copy {
    job: String,
    workspace_id: String,
    project_ref: String,
    revision: String,
}

/// The oracle's copy request, submitted and run.
fn copy(owners: &Owners) -> Copy {
    let source_revision = revision(&[
        ("Sources/App.txt", b"old\n"),
        ("Sources/Other.txt", b"outside the narrowed scope\n"),
    ]);
    let params = json!({"requestJson": json!({
        "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
        "requestId": "request-copy", "idempotencyKey": "idempotency-copy",
        "target": {"targetId": "workspace-host"},
        "operation": {"id": "workspace.prepare-isolated-copy", "version": 1},
        "inputs": {"projectRef": PROJECT, "allowedFileGlobs": ["Sources/App.txt"],
            "expectedWorkspaceRevision": source_revision},
        "requestedOutputs": ["derivedArtifacts"],
    }).to_string()});
    let submitted = owners.submit(&params);
    let job = submitted["result"]["jobId"].as_str().unwrap().to_owned();
    let ran = owners.run(&job);
    assert_eq!(ran["result"]["state"], "succeeded", "{ran}");
    let isolated = revision(&[("Sources/App.txt", b"old\n")]);
    let digest = sha256_hex(format!("runtime-{job}|{PROJECT}|{isolated}").as_bytes());
    Copy {
        job,
        workspace_id: format!("evo-{}", &digest[..24]),
        project_ref: format!("evolution-{}", &digest[..20]),
        revision: isolated,
    }
}

/// The revision Swift's provider measures over the oracle profile's files.
fn revision(files: &[(&str, &[u8])]) -> String {
    let mut material = format!("profileVersion\t{PROFILE}\nhead\tabsent\nindex\tabsent\n");
    for (path, bytes) in files {
        material.push_str(&format!("file\t{path}\t{}\n", sha256_hex(bytes)));
    }
    sha256_hex(material.as_bytes())
}

/// An apply of the oracle's good patch to `project`.
fn apply(project: &str, revision: Option<&str>, label: &str) -> Value {
    let mut inputs = json!({"projectRef": project,
        "patchArtifactRef": "lease-v1:job-input-patch:ART-4ccb0a35050cacc5248ae8c1d2e9fb1c",
        "allowedFileGlobs": ["Sources/App.txt"]});
    if let Some(revision) = revision {
        inputs["expectedWorkspaceRevision"] = json!(revision);
    }
    json!({"requestJson": json!({
        "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
        "requestId": format!("request-{label}"), "idempotencyKey": format!("idempotency-{label}"),
        "target": {"targetId": "workspace-host"},
        "operation": {"id": "workspace.apply-patch", "version": 1},
        "inputs": inputs, "requestedOutputs": ["derivedArtifacts"],
    }).to_string()})
}

/// A patch tool whose bytes changed after its profile pinned them is never
/// run: a plan against it is refused as Swift refuses a drifted tool, and a
/// Job admitted while it was intact fails at its dispatch — the executable
/// is opened by the pinned digest — with nothing started and the copy as it
/// was.
#[test]
fn a_patch_tool_whose_bytes_changed_after_its_pin_is_never_run() {
    let fixture = support::fixture("workspace-patch-oracle");
    let root = Root::temporary("drift");
    let source = seed(&root, &fixture);
    let tool = root.join("tools/patch");
    let profile = oracle_profile(&source, &tool);
    // The swap lands between the step's lowering and its dispatch.
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
    let marker = root.join("swapped-tool-ran");
    let workspace = WorkspaceComposition::with_profiles(
        vec![profile],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap()
    .with_tool_dispatch(Box::new(Swapping {
        tool: tool.clone(),
        marker: marker.clone(),
    }));
    let owners = Owners::new(root, workspace);
    let copied = copy(&owners);
    let copy_file = owners
        .root
        .join("evolution-workspaces")
        .join(&copied.workspace_id)
        .join("workspace/Sources/App.txt");
    let submitted = owners.submit(&apply(&copied.project_ref, Some(&copied.revision), "swap"));
    let job = submitted["result"]["jobId"].as_str().unwrap().to_owned();
    let ran = owners.run(&job);
    assert_eq!(ran["result"]["state"], "failed", "{ran}");
    let record = owners.record(&job);
    let timeline = serde_json::to_string(&record["timeline"]).unwrap();
    assert!(timeline.contains("failed apply-patch"), "{timeline}");
    assert!(timeline.contains("dispatch refused: "), "{timeline}");
    assert!(!marker.exists(), "the swapped tool never ran");
    assert_eq!(fs::read(&copy_file).unwrap(), b"old\n");
    // The use the Job consumed is settled: its dispatch was refused.
    assert_eq!(record["admissionEvidence"]["kind"], "runtimeCapability");
    // Now drifted, the tool leaves the operation unavailable at plan time.
    let plan = owners.plan(&apply(
        &copied.project_ref,
        Some(&copied.revision),
        "drifted",
    ));
    assert_eq!(
        plan,
        refused(
            "invalidInput",
            "workspace.apply-patch@1 is runtime unavailable: workspace.toolIdentityDrift",
            Some(proven())
        )
    );
}

/// A patch interrupted while its child runs — the daemon gone before any
/// outcome — is parked by the restarted Runtime with its intent outstanding,
/// is refused another run, is answered by a reconcile that reads nothing back
/// and resends nothing, and keeps the same mutation from being admitted
/// again while its use is unsettled. The copy it changed is not adopted (no
/// durable attempt vouches for it), and its uncertain Job still keeps the
/// source project from changing.
#[test]
fn an_interrupted_patch_is_parked_and_never_run_again() {
    let fixture = support::fixture("workspace-patch-oracle");
    let root = Root::temporary("interrupted");
    let source = seed(&root, &fixture);
    let profile = oracle_profile(&source, &root.join("tools/patch"));
    struct Crashing(Arc<AtomicUsize>);
    impl WorkspaceToolDispatch for Crashing {
        fn dispatch(&self, invocation: &ToolInvocation<'_>) -> Result<ToolReceipt, ToolFailure> {
            self.0.fetch_add(1, Ordering::SeqCst);
            let _ = VerifiedToolDispatch.dispatch(invocation);
            panic!("the daemon stops while the patch it started is outstanding");
        }
    }
    let started = Arc::new(AtomicUsize::new(0));
    let workspace = WorkspaceComposition::with_profiles(
        vec![profile.clone()],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap()
    .with_tool_dispatch(Box::new(Crashing(Arc::clone(&started))));
    let owners = Owners::new(root, workspace);
    let copied = copy(&owners);
    let params = apply(&copied.project_ref, Some(&copied.revision), "interrupted");
    let submitted = owners.submit(&params);
    let job = submitted["result"]["jobId"].as_str().unwrap().to_owned();
    let crashed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| owners.run(&job)));
    assert!(crashed.is_err());
    assert_eq!(started.load(Ordering::SeqCst), 1);
    let durable = owners.record(&job);
    assert_eq!(durable["state"], "running");
    assert_eq!(durable["recoveryAction"]["kind"], "workspace.action");
    // The daemon starts again over the same state.
    let Owners {
        root,
        jobs,
        capabilities,
        ..
    } = owners;
    drop((jobs, capabilities));
    let restarted = Arc::new(AtomicUsize::new(0));
    let workspace = WorkspaceComposition::with_profiles(
        vec![profile.clone()],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap()
    .with_tool_dispatch(Box::new(Crashing(Arc::clone(&restarted))));
    // The copy the child changed is not vouched for by any attempt.
    assert_eq!(
        workspace.adopt_runtime_workspaces(),
        [format!("{}:revision", copied.workspace_id)]
    );
    let owners = Owners::new(root, workspace);
    let recovered =
        recover_active_jobs(&owners.jobs, Some(&owners.capabilities), oracle_now).unwrap();
    assert_eq!(recovered.statuses.len(), 1);
    assert_eq!(recovered.statuses[0]["state"], "waitingForRecovery");
    let rerun = owners.run(&job);
    assert_eq!(
        rerun,
        refused(
            "resourceConflict",
            &format!("job {job} is waitingForRecovery, not runnable"),
            Some(proven())
        )
    );
    let reconciled = owners.reconcile(&job);
    assert_eq!(
        reconciled["result"]["state"], "waitingForRecovery",
        "{reconciled}"
    );
    let timeline: Vec<String> =
        serde_json::from_value(owners.record(&job)["timeline"].clone()).unwrap();
    assert_eq!(
        timeline.last().unwrap(),
        "reconcile inconclusive: mutation has no dedicated readback; original not resent"
    );
    // The use stays unknown, so its capability admits no new execution; and
    // no Job can name the copy no attempt vouches for.
    let evidence = &owners.record(&job)["admissionEvidence"];
    let status = owners
        .capabilities
        .handle(
            "capability.inspect",
            json!({"capabilityId": evidence["reference"]})
                .as_object()
                .unwrap(),
        )
        .unwrap();
    assert_eq!(status["lineageAllowsNewExecution"], false, "{status}");
    assert_eq!(
        status["lineageBlocker"], "use 1 is outcomeUnknown",
        "{status}"
    );
    let again = owners.submit(&apply(&copied.project_ref, Some(&copied.revision), "again"));
    assert_eq!(
        again,
        refused(
            "invalidInput",
            &format!(
                "typed plan preflight failed before authorization: \
                 workspace.projectProfileUnavailable:{}",
                copied.project_ref
            ),
            Some(proven())
        )
    );
    assert_eq!(restarted.load(Ordering::SeqCst), 0, "nothing started again");
    // The source project stays referenced by the copy's uncertain Job, though
    // no profile of this Runtime names the copy.
    assert_eq!(
        owners
            .workspace
            .registration_project_ref(&copied.project_ref),
        None
    );
    let census = owners
        .jobs
        .require_no_active_workspace_project_reference(PROJECT, &|reference| {
            owners.workspace.census_registration(reference)
        })
        .unwrap_err();
    assert_eq!(census.code, "resourceConflict");
    assert_eq!(
        census.message,
        "workspace project is referenced by an active or uncertain Job"
    );
    let _ = copied.job;
}

/// The production preset's own tool: `/usr/bin/patch`, pinned by its digest
/// when the profile was composed, applies a patch to a Runtime-owned copy
/// and reverts it exactly, and the restarted Runtime adopts the copy after
/// each through the durable patch lineage.
#[test]
fn the_real_patch_applies_and_reverts_a_copy_through_the_lineage() {
    let fixture = support::fixture("workspace-patch-oracle");
    let root = Root::temporary("real");
    let source = seed(&root, &fixture);
    let profile = oracle_profile(&source, Path::new("/usr/bin/patch"));
    let workspace = WorkspaceComposition::with_profiles(
        vec![profile.clone()],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap();
    let owners = Owners::new(root, workspace);
    let copied = copy(&owners);
    let file = owners
        .root
        .join("evolution-workspaces")
        .join(&copied.workspace_id)
        .join("workspace/Sources/App.txt");
    let params = apply(&copied.project_ref, Some(&copied.revision), "real");
    let planned = owners.plan(&params);
    assert_eq!(planned["ok"], true, "{planned}");
    let submitted = owners.submit(&params);
    let job = submitted["result"]["jobId"].as_str().unwrap().to_owned();
    let ran = owners.run(&job);
    assert_eq!(ran["result"]["state"], "succeeded", "{ran}");
    assert_eq!(fs::read(&file).unwrap(), b"new\n");
    assert_eq!(fs::read(source.join("Sources/App.txt")).unwrap(), b"old\n");
    assert_eq!(adoption(&owners.root.0, &profile), Vec::<String>::new());
    let reference = format!(
        "patch-{}",
        &sha256_hex(
            format!(
                "{job}\n{}\n{}",
                "f0a60ff8aa51ca5b39e950bf7c57dc8707ccea707c5d7c1eb6ac72797438ed4a",
                copied.project_ref
            )
            .as_bytes()
        )[..32]
    );
    let revert = json!({"requestJson": json!({
        "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
        "requestId": "request-real-revert", "idempotencyKey": "idempotency-real-revert",
        "target": {"targetId": "workspace-host"},
        "operation": {"id": "workspace.revert-patch", "version": 1},
        "inputs": {"projectRef": copied.project_ref, "patchAttemptRef": reference},
        "requestedOutputs": ["derivedArtifacts"],
    }).to_string()});
    let submitted = owners.submit(&revert);
    assert_eq!(submitted["ok"], true, "{submitted}");
    let job = submitted["result"]["jobId"].as_str().unwrap().to_owned();
    let ran = owners.run(&job);
    assert_eq!(ran["result"]["state"], "succeeded", "{ran}");
    assert_eq!(fs::read(&file).unwrap(), b"old\n");
    assert_eq!(adoption(&owners.root.0, &profile), Vec::<String>::new());
    let result = owners.result(&job);
    assert_eq!(
        result["result"]["artifacts"][0]["name"],
        "revert-report.json"
    );
}

/// Patch steps of one Runtime run one at a time, as Swift's mutation lane
/// runs a target's mutation Jobs: while one patch is dispatched, a second Job
/// that would change the same copy waits, then finds the copy moved and fails
/// before its intent. The first dispatch holds its child until a second one
/// starts or two seconds pass, so a runner without the lane is seen starting
/// a second child meanwhile.
#[test]
fn patch_steps_run_one_at_a_time() {
    use std::sync::Condvar;
    use std::time::Duration;
    let fixture = support::fixture("workspace-patch-oracle");
    let root = Root::temporary("lane");
    let source = seed(&root, &fixture);
    let profile = oracle_profile(&source, &root.join("tools/patch"));
    #[derive(Default)]
    struct Ordered {
        events: Mutex<Vec<&'static str>>,
        started: Condvar,
    }
    struct Holding(Arc<Ordered>);
    impl WorkspaceToolDispatch for Holding {
        fn dispatch(&self, invocation: &ToolInvocation<'_>) -> Result<ToolReceipt, ToolFailure> {
            let mut events = self.0.events.lock().unwrap();
            events.push("start");
            self.0.started.notify_all();
            if events.len() == 1 {
                let (held, _) = self
                    .0
                    .started
                    .wait_timeout_while(events, Duration::from_secs(2), |events| events.len() == 1)
                    .unwrap();
                events = held;
            }
            drop(events);
            let receipt = VerifiedToolDispatch.dispatch(invocation);
            self.0.events.lock().unwrap().push("end");
            receipt
        }
    }
    let ordered = Arc::new(Ordered::default());
    let workspace = WorkspaceComposition::with_profiles(
        vec![profile],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap()
    .with_tool_dispatch(Box::new(Holding(Arc::clone(&ordered))));
    let owners = Owners::new(root, workspace);
    let copied = copy(&owners);
    let copy_file = owners
        .root
        .join("evolution-workspaces")
        .join(&copied.workspace_id)
        .join("workspace/Sources/App.txt");
    // Two Jobs of the same patch against the same revision, admitted before
    // either runs, under two capabilities: one scoped to the file, one to its
    // directory.
    let narrow = owners.submit(&apply(
        &copied.project_ref,
        Some(&copied.revision),
        "narrow",
    ));
    let mut wide = apply(&copied.project_ref, Some(&copied.revision), "wide");
    let mut document: Value = serde_json::from_str(wide["requestJson"].as_str().unwrap()).unwrap();
    document["inputs"]["allowedFileGlobs"] = json!(["Sources/**"]);
    wide["requestJson"] = json!(document.to_string());
    let wide = owners.submit(&wide);
    let (first_job, second_job) = (
        narrow["result"]["jobId"]
            .as_str()
            .expect("admitted")
            .to_owned(),
        wide["result"]["jobId"]
            .as_str()
            .expect("admitted")
            .to_owned(),
    );
    let (first, second) = std::thread::scope(|scope| {
        let first = scope.spawn(|| owners.run(&first_job));
        // The second run starts once the first child is being dispatched.
        let (events, waited) = ordered
            .started
            .wait_timeout_while(
                ordered.events.lock().unwrap(),
                Duration::from_secs(60),
                |events| events.is_empty(),
            )
            .unwrap();
        drop(events);
        assert!(!waited.timed_out(), "the first patch was never dispatched");
        let second = scope.spawn(|| owners.run(&second_job));
        (first.join().unwrap(), second.join().unwrap())
    });
    assert_eq!(*ordered.events.lock().unwrap(), ["start", "end"]);
    assert_eq!(first["result"]["state"], "succeeded", "{first}");
    assert_eq!(second["result"]["state"], "failed", "{second}");
    let timeline = serde_json::to_string(&owners.record(&second_job)["timeline"]).unwrap();
    assert!(
        timeline.contains("workspace.revisionConflict"),
        "{timeline}"
    );
    assert!(!timeline.contains("intent apply-patch"), "{timeline}");
    assert_eq!(fs::read(&copy_file).unwrap(), b"new\n");
}
