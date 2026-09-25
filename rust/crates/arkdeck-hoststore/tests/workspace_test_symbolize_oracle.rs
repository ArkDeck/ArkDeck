//! Replays the Swift oracle of `workspace.run-tests@1` and
//! `workspace.symbolize-crash@1`
//! (`rust/tests/fixtures/workspace-test-symbolize-oracle`, recorded by
//! `WorkspaceTestSymbolizeOracleContractTests`) against the Rust planner,
//! admitter, runner, reconciler and result reader over the same fixed root,
//! profile, stand-in toolchain and symbolizer, seeded crash logs and clock:
//! every answer must be Swift's (the plan's additive review digest aside) and
//! admitted by the published method schemas, and what the Runtime keeps
//! afterwards — the capability store, the published products and the durable
//! records of the two parked Jobs — Swift's byte for byte.
//!
//! The same binary pins what the oracle cannot show: a test or symbol tool
//! whose bytes changed after its pin is never run; a person's primary tree is
//! never tested, not even under a grant the store holds; and a symbol preset
//! whose symbolizer is this daemon in its one-shot mode resolves the device's
//! own crash stack through the project's source map.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, JobAdmitter, JobPlanner, JobReconciler,
    JobResultReader, JobRunner, JobStore, MutationAuthority, MutationExecution, ProfilePresets,
    ToolFailure, ToolInvocation, ToolReceipt, VerifiedResource, VerifiedToolDispatch,
    WorkspaceCommandPreset, WorkspaceComposition, WorkspaceProfile, WorkspaceToolDispatch,
};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use support::chmod;

/// The recording's fixed root: the profile pins the source tree, the tools
/// and the SDK root by path, and the argv names the map and the dump.
const ROOT: &str = "/private/tmp/arkdeck-workspace-test-symbolize-oracle";
const LOCK: &str = "/private/tmp/arkdeck-workspace-test-symbolize-oracle.lock";
const TIMESTAMP: &str = "2026-09-25T00:00:00Z";
const PROJECT: &str = "TestSymbolizeOracleProject";
const PROFILE: &str = "workspace-test-symbolize-oracle@1";
const SCOPE: &str = "entry/src/main/ets/**";
const TESTS: &str = "oracle-tests";
const FAILING: &str = "oracle-failing-tests";
const SYMBOL: &str = "arkts-sourcemap";
const MISSING_MAP: &str = "missing-map";
const SOURCE_MAP: &str = "entry/build/default/outputs/default/mapping/sourceMaps.map";
const INPUT_JOBS: [&str; 2] = ["job-input-crash", "job-input-host-crash"];
const LOST_AFTER: &str =
    "dispatch outcome unobservable: the oracle lost the receipt after the child ran";

fn oracle_now() -> Option<String> {
    Some(TIMESTAMP.into())
}

fn text(path: &Path) -> String {
    path.to_str().unwrap().to_owned()
}

/// Foundation's spelling of a physical path below `/private`.
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

/// Whether the dispatch hands its receipt back, and how many children it
/// started.
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
            "arkdeck-workspace-test-symbolize-{label}-{:x}",
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

/// The oracle's project, its tools and the crash logs a device capture
/// published before the first request.
struct Oracle {
    source: PathBuf,
    node: PathBuf,
    hvigor: PathBuf,
    symbolizer: PathBuf,
    sdk: PathBuf,
}

fn seed(root: &Root, fixture: &Path) -> Oracle {
    let source = root.join("source");
    for (path, contents) in [
        (
            "entry/src/main/ets/entryability/EntryAbility.ets",
            "export default class EntryAbility {}\n",
        ),
        (
            "entry/src/main/ets/pages/Index.ets",
            "@Entry\n@Component\nstruct Index {\n  build() {}\n}\n",
        ),
        (
            "entry/src/main/module.json5",
            "{ module: { name: 'entry' } }\n",
        ),
        (
            SOURCE_MAP,
            "{\"entry|entry|1.0.0|src/main/ets/h/l.ts\":{\"mappings\":\"AAAA\",\"sources\":[\"a.ets\"]}}\n",
        ),
    ] {
        fs::create_dir_all(source.join(path).parent().unwrap()).unwrap();
        fs::write(source.join(path), contents).unwrap();
    }
    let tools = root.join("tools");
    fs::create_dir(&tools).unwrap();
    fs::create_dir(root.join("sdk")).unwrap();
    for (name, fixture_name, mode) in [
        ("node", "node.sh", 0o755),
        ("hvigorw.js", "hvigorw.js", 0o644),
        ("symbolizer", "symbolizer.sh", 0o755),
    ] {
        fs::copy(fixture.join(fixture_name), tools.join(name)).unwrap();
        chmod(&tools.join(name), mode);
    }
    for job in INPUT_JOBS {
        let directory = root.join("artifacts").join(job);
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
        for file in fs::read_dir(fixture.join("artifacts").join(job)).unwrap() {
            let file = file.unwrap().path();
            let name = file.file_name().unwrap();
            fs::copy(&file, directory.join(name)).unwrap();
            chmod(
                &directory.join(name),
                if name == "index.json" { 0o600 } else { 0o400 },
            );
        }
    }
    let tools = tools.canonicalize().unwrap();
    Oracle {
        source: source.canonicalize().unwrap(),
        node: tools.join("node"),
        hvigor: tools.join("hvigorw.js"),
        symbolizer: tools.join("symbolizer"),
        sdk: root.join("sdk").canonicalize().unwrap(),
    }
}

/// A registered Hvigor test preset's closed argv.
fn hvigor_arguments(script: &str, module: &str) -> Vec<String> {
    [
        script,
        "test",
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

fn profile(setup: &Oracle, symbolizer: &Path) -> WorkspaceProfile {
    let script = foundation(&setup.hvigor);
    let bytes = fs::read(&setup.hvigor).unwrap();
    let resource = VerifiedResource {
        path: script.clone(),
        sha256: sha256_hex(&bytes),
        byte_count: bytes.len() as u64,
        require_executable: false,
    };
    let test = |id: &str, module: &str| {
        let arguments = hvigor_arguments(&script, module);
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        WorkspaceCommandPreset::hashing_with_resources(
            id,
            &text(&setup.node),
            None,
            &arguments,
            60,
            vec![resource.clone()],
        )
        .unwrap()
    };
    let symbol = |id: &str, map: &str| {
        let map = text(&setup.source.join(map));
        WorkspaceCommandPreset::hashing(
            id,
            &text(symbolizer),
            None,
            &["--symbolize-crash", &map],
            30,
        )
        .unwrap()
    };
    WorkspaceProfile::primary(
        PROFILE,
        PROJECT,
        &text(&setup.source),
        &[SCOPE],
        WorkspaceCommandPreset::hashing("inspect", "/usr/bin/grep", None, &[], 10).unwrap(),
        WorkspaceCommandPreset::hashing("patch", "/usr/bin/grep", None, &[], 10).unwrap(),
        ProfilePresets {
            test: vec![test(TESTS, "entry"), test(FAILING, "broken")],
            symbol: vec![
                symbol(SYMBOL, SOURCE_MAP),
                symbol(MISSING_MAP, "entry/build/missing/sourceMaps.map"),
            ],
            ..ProfilePresets::default()
        },
    )
    .unwrap()
}

fn composition(
    root: &Root,
    setup: &Oracle,
    symbolizer: &Path,
    dispatch: Box<dyn WorkspaceToolDispatch>,
) -> WorkspaceComposition {
    WorkspaceComposition::with_profiles(
        vec![profile(setup, symbolizer)],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap()
    .with_tool_dispatch(dispatch)
    .with_child_environment(
        &text(&setup.node),
        &[("DEVECO_SDK_HOME", &text(&setup.sdk))],
    )
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
            let name = path.file_name().unwrap().to_string_lossy();
            name.starts_with(prefix) && !name.starts_with('.')
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

fn request_id(params: &Value) -> Option<String> {
    let document: Value = serde_json::from_str(params["requestJson"].as_str()?).ok()?;
    document["requestId"].as_str().map(str::to_owned)
}

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

#[test]
fn the_rust_runtime_answers_the_recorded_tests_and_symbolizations() {
    let _held = exclusive();
    let fixture = support::fixture("workspace-test-symbolize-oracle");
    let provenance = support::document(&fixture, "provenance.json");
    for (name, digest) in provenance["files"].as_object().unwrap() {
        assert_eq!(
            sha256_hex(&fs::read(fixture.join(name)).unwrap()),
            digest.as_str().unwrap(),
            "{name} is the recorded file"
        );
    }
    let root = Root::fixed();
    let setup = seed(&root, &fixture);
    let loss = Arc::new(Loss::default());
    let workspace = composition(
        &root,
        &setup,
        &setup.symbolizer,
        Box::new(LosingDispatch(Arc::clone(&loss))),
    );
    let owners = Owners::new(root, workspace);
    let frames: Vec<Value> = fs::read_to_string(fixture.join("frames.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(frames.len(), 37);
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
    // Three test runs and three symbolizations reached their dispatch; the two
    // parked Jobs were never started again.
    assert_eq!(loss.started.load(Ordering::SeqCst), 6);
    assert_eq!(
        files(&owners.root.join("jobs-state/capabilities"), ""),
        files(&fixture.join("capabilities"), "")
    );
    for job in fs::read_dir(fixture.join("artifacts")).unwrap() {
        let job = job.unwrap().file_name();
        if INPUT_JOBS.contains(&job.to_str().unwrap()) {
            continue;
        }
        assert_eq!(
            files(&owners.root.join("artifacts").join(&job), "ART-"),
            files(&fixture.join("artifacts").join(&job), "ART-"),
            "{job:?}'s published products"
        );
    }
    for (name, label) in [
        ("parked-tests-record.json", "request-tests-lost"),
        ("parked-symbolize-record.json", "request-symbolize-lost"),
    ] {
        let recorded = support::document(&fixture, name);
        let job = &jobs[label];
        assert_eq!(recorded["jobID"], json!(job));
        assert_eq!(parked[job.as_str()], recorded, "{name}");
    }
}

/// The copy a test run needs: made by the Runtime from the primary tree,
/// named by its derived reference, with its base revision.
fn copy(owners: &Owners) -> (String, String) {
    let revision = |files: &[(&str, &str)]| {
        let mut material = format!("profileVersion\t{PROFILE}\nhead\tabsent\nindex\tabsent\n");
        for (path, contents) in files {
            material.push_str(&format!(
                "file\t{path}\t{}\n",
                sha256_hex(contents.as_bytes())
            ));
        }
        sha256_hex(material.as_bytes())
    };
    let base = revision(&[
        (
            "entry/src/main/ets/entryability/EntryAbility.ets",
            "export default class EntryAbility {}\n",
        ),
        (
            "entry/src/main/ets/pages/Index.ets",
            "@Entry\n@Component\nstruct Index {\n  build() {}\n}\n",
        ),
    ]);
    let accepted = owners.submit(&request(
        "copy",
        "workspace.prepare-isolated-copy",
        json!({"projectRef": PROJECT, "allowedFileGlobs": [SCOPE],
            "expectedWorkspaceRevision": base}),
        None,
    ));
    let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
    assert_eq!(owners.run(&job)["result"]["state"], "succeeded");
    let digest = sha256_hex(format!("runtime-{job}|{PROJECT}|{base}").as_bytes());
    (format!("evolution-{}", &digest[..20]), base)
}

/// A test or symbol tool whose bytes changed after its profile pinned them is
/// never run: the fresh action refuses before any intent — the whole profile
/// is re-measured — with nothing started, and a plan names the drift.
#[test]
fn a_test_or_symbol_tool_that_changed_after_its_pin_is_never_run() {
    let fixture = support::fixture("workspace-test-symbolize-oracle");
    for drifted in ["node", "symbolizer"] {
        let root = Root::temporary("drift");
        let setup = seed(&root, &fixture);
        let loss = Arc::new(Loss::default());
        let workspace = composition(
            &root,
            &setup,
            &setup.symbolizer,
            Box::new(LosingDispatch(Arc::clone(&loss))),
        );
        let owners = Owners::new(root, workspace);
        let (operation, inputs) = if drifted == "node" {
            let (copy, base) = copy(&owners);
            (
                "workspace.run-tests",
                json!({"projectRef": copy, "testPresetRef": TESTS,
                    "expectedWorkspaceRevision": base}),
            )
        } else {
            let index: Value =
                support::document(&owners.root.join("artifacts/job-input-crash"), "index.json");
            let artifact = index["artifacts"]
                .as_array()
                .unwrap()
                .iter()
                .find(|row| row["name"] == "crash-log.txt")
                .unwrap()["artifactID"]
                .as_str()
                .unwrap()
                .to_owned();
            (
                "workspace.symbolize-crash",
                json!({"projectRef": PROJECT, "symbolPresetRef": SYMBOL,
                    "dumpArtifactRef": format!("lease-v1:job-input-crash:{artifact}")}),
            )
        };
        let accepted = owners.submit(&request("drift", operation, inputs.clone(), None));
        let job = accepted["result"]["jobId"]
            .as_str()
            .unwrap_or_else(|| panic!("{drifted}: {accepted}"))
            .to_owned();
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
        let timeline = serde_json::to_string(&owners.record(&job)["timeline"]).unwrap();
        assert!(!timeline.contains("\"intent "), "{drifted}: {timeline}");
        assert!(
            timeline.contains("workspace.toolIdentityDrift"),
            "{drifted}: {timeline}"
        );
        let plan = owners.plan(&request("drifted", operation, inputs, None));
        assert_eq!(plan["ok"], false, "{drifted}: {plan}");
        assert!(
            plan["error"]["message"]
                .as_str()
                .unwrap()
                .ends_with("workspace.toolIdentityDrift"),
            "{drifted}: {plan}"
        );
    }
}

/// A person's primary tree needs a standing capability a person issued,
/// which this Runtime neither issues nor honours: a test run naming none is
/// refused as Swift refuses it, and one naming a grant the store holds for
/// exactly this tree is refused as a capability the store does not hold.
/// Nothing is admitted and nothing runs.
#[test]
fn a_primary_tree_is_never_tested_even_under_a_person_issued_grant() {
    let fixture = support::fixture("workspace-test-symbolize-oracle");
    let root = Root::temporary("primary");
    let setup = seed(&root, &fixture);
    let loss = Arc::new(Loss::default());
    let workspace = composition(
        &root,
        &setup,
        &setup.symbolizer,
        Box::new(LosingDispatch(Arc::clone(&loss))),
    );
    let owners = Owners::new(root, workspace);
    let identity =
        sha256_hex(format!("arkdeck-workspace|{PROFILE}|{}", foundation(&setup.source)).as_bytes());
    let grant = arkdeck_hoststore::RuntimeCapability::from_value(&json!({
        "capabilityID": "CAP-RT-PERSON-ISSUED-TESTS",
        "targetScope": {"kind": "workspaceIdentity", "sha256": identity,
            "expectedWorkspaceRevision": "", "allowedFileScopesDigest": sha256_hex(SCOPE.as_bytes())},
        "operationScope": [{"operationID": "workspace.run-tests", "version": 1}],
        "effectCeiling": "deviceMutation",
        "inputConstraints": {},
        "issuedAtUTC": "2026-09-24T00:00:00Z", "expiresAtUTC": "2026-10-24T00:00:00Z",
        "maximumUses": 10,
        "issuer": {"kind": "maintainerMergedPR", "reference": "pr:0"},
        "revocation": {"state": "active"},
    }))
    .unwrap();
    owners.capabilities.install(&grant).unwrap();
    let inputs = json!({"projectRef": PROJECT, "testPresetRef": TESTS});
    for (label, capability, message) in [
        (
            "primary",
            None,
            "effect deviceMutation requires an explicit runtime capability".to_owned(),
        ),
        (
            "primary-granted",
            Some("CAP-RT-PERSON-ISSUED-TESTS"),
            "capability denied [denial:capabilityNotFound]: \
             capabilityNotFound(\"CAP-RT-PERSON-ISSUED-TESTS\")"
                .to_owned(),
        ),
    ] {
        let answer = owners.submit(&request(
            label,
            "workspace.run-tests",
            inputs.clone(),
            capability,
        ));
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
    assert_eq!(loss.started.load(Ordering::SeqCst), 0);
}
