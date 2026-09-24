//! Replays the Swift `workspace.prepare-isolated-copy@1` oracle
//! (`rust/tests/fixtures/workspace-isolation-oracle`, recorded by
//! `WorkspaceIsolationOracleContractTests`, #2094) against the Rust planner,
//! admitter, runner and result reader: the same source tree, profile and
//! clock, then `job.plan`, `job.submit`, `job.run` and `job.result` in the
//! recorded order. Every answer must be Swift's (the plan's additive review
//! digest aside), the copy's manifest Swift's byte for byte and its tree
//! Swift's file for file.
//!
//! The same binary pins what the oracle cannot show: a restarted Runtime
//! adopting the copies a previous one made, and refusing the ones it cannot
//! vouch for; the copy's exclusions and link rules; a refusal that names the
//! offending entry and no host path; a source that moved after admission;
//! and the registration a Job holds while it is materialized.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, JobAdmitter, JobPlanner, JobResultReader, JobRunner, JobStore,
    ProfilePresets, WorkspaceCommandPreset, WorkspaceComposition, WorkspaceProfile,
    WorkspaceProjectStore,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

const TIMESTAMP: &str = "2026-09-20T00:00:00.000Z";
const PROJECT: &str = "IsolationOracleProject";
const PROFILE: &str = "workspace-isolation-oracle@1";
const WORKSPACE_ID: &str = "evo-e2ae7c7152894a5b51d95e92";
const COPY_REF: &str = "evolution-e2ae7c7152894a5b51d9";

fn oracle_now() -> Option<String> {
    Some(TIMESTAMP.into())
}

/// A private scratch root, removed when the test ends.
struct Root(PathBuf);

impl Root {
    fn new(label: &str) -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-workspace-isolation-{label}-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for directory in [
            root.clone(),
            root.join("artifacts"),
            root.join("jobs-state"),
        ] {
            fs::create_dir(&directory).unwrap();
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
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

fn text(path: &Path) -> String {
    path.to_str().unwrap().to_owned()
}

/// The oracle's source tree: one file inside the narrowed scope, one
/// outside it but inside the profile's.
fn source_tree(root: &Root) -> PathBuf {
    let source = root.join("source");
    fs::create_dir_all(source.join("Sources")).unwrap();
    fs::write(source.join("Sources/App.txt"), "old\n").unwrap();
    fs::write(
        source.join("Sources/Other.txt"),
        "outside the narrowed scope\n",
    )
    .unwrap();
    source
}

/// The oracle's profile: `Sources/**`, grep and patch pinned by digest.
fn oracle_profile(source: &Path) -> WorkspaceProfile {
    WorkspaceProfile::primary(
        PROFILE,
        PROJECT,
        &text(source),
        &["Sources/**"],
        WorkspaceCommandPreset::hashing("inspect", "/usr/bin/grep", None, &[], 10).unwrap(),
        WorkspaceCommandPreset::hashing("patch", "/usr/bin/patch", None, &[], 10).unwrap(),
        ProfilePresets::default(),
    )
    .unwrap()
}

/// The Runtime around one composition, as the Swift oracle composed its
/// engine: no session writer, no mutation authority, no HDC.
struct Owners {
    root: Root,
    jobs: JobStore,
    artifacts: ArtifactReadStore,
    workspace: WorkspaceComposition,
}

impl Owners {
    fn new(root: Root, workspace: WorkspaceComposition) -> Self {
        Self {
            jobs: JobStore::open_owner(&root.join("jobs-state")).unwrap(),
            artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
            workspace,
            root,
        }
    }
    fn oracle(label: &str) -> Self {
        let root = Root::new(label);
        let source = source_tree(&root);
        let workspace = WorkspaceComposition::with_profiles(
            vec![oracle_profile(&source)],
            &root.join("evolution-workspaces"),
            oracle_now,
        )
        .unwrap();
        Self::new(root, workspace)
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
            Err(refusal) => {
                json!({"ok": false, "error": {"code": refusal.code, "message": refusal.message}})
            }
        }
    }
    fn submit(&self, params: &Value) -> Value {
        let admitter = JobAdmitter {
            planner: self.planner(),
            jobs: &self.jobs,
            now: oracle_now,
            authority: None,
        };
        match admitter.handle(params.as_object().unwrap()) {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(refusal) => {
                json!({"ok": false, "error": {"code": refusal.code, "message": refusal.message}})
            }
        }
    }
    fn run(&self, job: &str) -> Value {
        let runner = JobRunner {
            mutation: None,
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
            Err(refusal) => {
                json!({"ok": false, "error": {"code": refusal.code, "message": refusal.message}})
            }
        }
    }
    fn result(&self, job: &str) -> Value {
        let reader = JobResultReader {
            jobs: &self.jobs,
            artifacts: &self.artifacts,
        };
        match reader.handle("job.result", json!({"jobId": job}).as_object().unwrap()) {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(error) => {
                json!({"ok": false, "error": {"code": error.code, "message": error.message}})
            }
        }
    }
    fn record(&self, job: &str) -> Value {
        self.jobs.read_snapshot(job).unwrap().value().unwrap()
    }
    fn evolution(&self, relative: &str) -> PathBuf {
        self.root.join("evolution-workspaces").join(relative)
    }
}

/// A prepare request as the Swift oracle encoded it, named by `label`.
fn request(inputs: Value, label: &str) -> Value {
    json!({"requestJson": json!({
        "idempotencyKey": format!("idempotency-{label}"),
        "documentType": "runtime-operation-request",
        "requestId": format!("request-{label}"), "inputs": inputs,
        "operation": {"id": "workspace.prepare-isolated-copy", "version": 1},
        "requestedOutputs": ["derivedArtifacts"], "schemaVersion": "1.0.0",
        "target": {"targetId": "workspace-host"},
    }).to_string()})
}

/// The revision Swift's provider measures for `globs` over the oracle's
/// source files, from their bytes.
fn revision(files: &[(&str, &[u8])]) -> String {
    let mut material = format!("profileVersion\t{PROFILE}\nhead\tabsent\nindex\tabsent\n");
    for (path, bytes) in files {
        material.push_str(&format!("file\t{path}\t{}\n", sha256_hex(bytes)));
    }
    sha256_hex(material.as_bytes())
}

/// Every regular file below `root`, tree-relative and sorted, with its
/// digest (the oracle's `tree(at:)`).
fn tree(root: &Path) -> Vec<(String, String)> {
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
}

/// Every entry below `root` by its kind: a directory and its mode, a file
/// and its mode and bytes, a link and its target.
fn entries(root: &Path) -> BTreeMap<String, String> {
    fn walk(root: &Path, directory: &Path, entries: &mut BTreeMap<String, String>) {
        for entry in fs::read_dir(directory).unwrap() {
            let path = entry.unwrap().path();
            let metadata = fs::symlink_metadata(&path).unwrap();
            let relative = text(path.strip_prefix(root).unwrap());
            let described = if metadata.file_type().is_symlink() {
                format!("link {}", text(&fs::read_link(&path).unwrap()))
            } else if metadata.is_dir() {
                walk(root, &path, entries);
                format!("directory {:o}", metadata.mode() & 0o777)
            } else {
                format!(
                    "file {:o} {}",
                    metadata.mode() & 0o777,
                    String::from_utf8_lossy(&fs::read(&path).unwrap())
                )
            };
            entries.insert(relative, described);
        }
    }
    let mut entries = BTreeMap::new();
    walk(root, root, &mut entries);
    entries
}

fn plan_and_run(owners: &Owners, inputs: Value, idempotency: &str) -> (String, Value) {
    let params = request(inputs, idempotency);
    let submitted = owners.submit(&params);
    assert_eq!(submitted["ok"], true, "{submitted}");
    let job = submitted["result"]["jobId"].as_str().unwrap().to_owned();
    let ran = owners.run(&job);
    (job, ran)
}

/// The identities of the copy `job` makes of the oracle project's
/// narrowed revision `isolated`: its workspace and its reference.
fn copy_of(job: &str, isolated: &str) -> (String, String) {
    let digest = sha256_hex(format!("runtime-{job}|{PROJECT}|{isolated}").as_bytes());
    (
        format!("evo-{}", &digest[..24]),
        format!("evolution-{}", &digest[..20]),
    )
}

fn isolated_revision() -> String {
    revision(&[("Sources/App.txt", b"old\n")])
}

fn source_revision() -> String {
    revision(&[
        ("Sources/App.txt", b"old\n"),
        ("Sources/Other.txt", b"outside the narrowed scope\n"),
    ])
}

fn oracle_inputs() -> Value {
    json!({"projectRef": PROJECT, "expectedWorkspaceRevision": source_revision(),
        "allowedFileGlobs": ["Sources/App.txt"]})
}

#[test]
fn the_rust_runtime_answers_the_recorded_isolation_sequence() {
    let fixture = support::fixture("workspace-isolation-oracle");
    let provenance = support::document(&fixture, "provenance.json");
    for (name, digest) in provenance["files"].as_object().unwrap() {
        assert_eq!(
            sha256_hex(&fs::read(fixture.join(name)).unwrap()),
            digest.as_str().unwrap(),
            "{name} is the recorded file"
        );
    }
    let owners = Owners::oracle("oracle");
    let frames: Vec<Value> = fs::read_to_string(fixture.join("frames.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(frames.len(), 4);
    let mut job = String::new();
    for frame in &frames {
        let method = frame["method"].as_str().unwrap();
        let answer = match method {
            "job.plan" => support::legacy_plan_answer(owners.plan(&frame["params"])),
            "job.submit" => {
                let answer = owners.submit(&frame["params"]);
                job = answer["result"]["jobId"]
                    .as_str()
                    .unwrap_or_default()
                    .into();
                answer
            }
            "job.run" => owners.run(frame["params"]["jobId"].as_str().unwrap()),
            "job.result" => owners.result(frame["params"]["jobId"].as_str().unwrap()),
            other => panic!("the oracle records no {other}"),
        };
        let recorded = json!({"ok": frame["ok"], "result": frame["result"]});
        assert_eq!(answer, recorded, "{method}");
    }
    assert_eq!(job, "job-825787507429b81047c9726a1373a83b");
    // The copy the Runtime owns afterwards: its manifest, byte for byte, and
    // the whole profile scope in its tree, file for file.
    let copy = owners.evolution(WORKSPACE_ID);
    assert_eq!(
        String::from_utf8(fs::read(copy.join("workspace.json")).unwrap()).unwrap(),
        String::from_utf8(fs::read(fixture.join("workspace.json")).unwrap()).unwrap()
    );
    let recorded = support::document(&fixture, "tree.json");
    assert_eq!(recorded["workspaceID"], WORKSPACE_ID);
    assert_eq!(recorded["sourceRevision"], source_revision());
    let entries: Vec<(String, String)> = recorded["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| {
            (
                entry["path"].as_str().unwrap().to_owned(),
                entry["sha256"].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    assert_eq!(tree(&copy.join("workspace")), entries);
    assert!(copy.join("attempts").is_dir());
    assert!(!copy.join(".workspace.tmp").exists());
    // The Runtime owns the copy; nothing else in it is writable by others.
    for path in [copy.clone(), copy.join("workspace")] {
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o700);
    }
    // The primary tree is untouched, and the copy resolves to its source's
    // registration.
    assert_eq!(
        fs::read(owners.root.join("source/Sources/App.txt")).unwrap(),
        b"old\n"
    );
    assert_eq!(
        owners
            .workspace
            .registration_project_ref(COPY_REF)
            .as_deref(),
        Some(PROJECT)
    );
    // The durable record keeps the typed action no longer: its intent closed.
    let record = owners.record(&job);
    assert!(record.get("recoveryAction").is_none(), "{record}");
    assert_eq!(
        record["actualStepKinds"],
        json!(["prepareWorkspaceIsolation"])
    );
    let timeline: Vec<String> = serde_json::from_value(record["timeline"].clone()).unwrap();
    assert!(timeline.contains(&"intent prepare-isolated-copy".to_owned()));
    assert!(
        timeline.contains(
            &"verified prepare-isolated-copy [\"allowedFileScopesDigest\", \"isolation\", \
          \"projectRef\", \"sourceProjectRef\", \"sourceWorkspaceRevision\", \"workspaceId\", \
          \"workspaceRevision\"]"
                .to_owned()
        )
    );
    // A plan is never admitted, a duplicate submit dispatches nothing new,
    // and a terminal Job is never run again.
    let again = owners.submit(&frames[1]["params"]);
    assert_eq!(again["result"]["deduplicated"], true);
    let rerun = owners.run(&job);
    assert_eq!(rerun["error"]["code"], "resourceConflict", "{rerun}");
}

/// The restart half of the lifecycle: a new Runtime over the same state
/// adopts the copy a previous one made, and names every copy it cannot vouch
/// for instead of resolving it.
#[test]
fn a_restarted_runtime_adopts_the_copies_a_previous_runtime_made() {
    let owners = Owners::oracle("adoption");
    let (job, ran) = plan_and_run(&owners, oracle_inputs(), "adoption");
    assert_eq!(ran["result"]["state"], "succeeded", "{ran}");
    let (workspace_id, copy_ref) = copy_of(&job, &isolated_revision());
    let (workspace_id, copy_ref) = (workspace_id.as_str(), copy_ref.as_str());
    let profile = oracle_profile(&owners.root.join("source"));
    let evolution = owners.root.join("evolution-workspaces");
    let restarted = || {
        WorkspaceComposition::with_profiles(vec![profile.clone()], &evolution, oracle_now).unwrap()
    };
    let fresh = restarted();
    assert_eq!(fresh.registration_project_ref(copy_ref), None);
    assert_eq!(fresh.adopt_runtime_workspaces(), Vec::<String>::new());
    assert_eq!(
        fresh.registration_project_ref(copy_ref).as_deref(),
        Some(PROJECT)
    );
    // A copy whose Job is not the Runtime's is not the Runtime's to adopt.
    let foreign = evolution.join("evo-000000000000000000000000");
    fs::create_dir(&foreign).unwrap();
    fs::write(
        foreign.join("workspace.json"),
        fs::read_to_string(evolution.join(workspace_id).join("workspace.json"))
            .unwrap()
            .replace("runtime-job-", "htask-job-")
            .replace(copy_ref, "evolution-00000000000000000000"),
    )
    .unwrap();
    assert_eq!(restarted().adopt_runtime_workspaces(), Vec::<String>::new());
    fs::remove_dir_all(&foreign).unwrap();
    // Without its source profile a copy is not adopted.
    let other = WorkspaceProfile::primary(
        PROFILE,
        "AnotherProject",
        &text(&owners.root.join("source")),
        &["Sources/**"],
        WorkspaceCommandPreset::hashing("inspect", "/usr/bin/grep", None, &[], 10).unwrap(),
        WorkspaceCommandPreset::hashing("patch", "/usr/bin/patch", None, &[], 10).unwrap(),
        ProfilePresets::default(),
    )
    .unwrap();
    let orphaned =
        WorkspaceComposition::with_profiles(vec![other], &evolution, oracle_now).unwrap();
    assert_eq!(
        orphaned.adopt_runtime_workspaces(),
        [format!("{workspace_id}:metadata")]
    );
    assert_eq!(orphaned.registration_project_ref(copy_ref), None);
    // A manifest whose scopes disagree with its digest is refused.
    let manifest = evolution.join(workspace_id).join("workspace.json");
    let original = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        original.replace(
            "\"Sources/App.txt\"\n  ]",
            "\"Sources/App.txt\",\n    \"Sources/Other.txt\"\n  ]",
        ),
    )
    .unwrap();
    let tampered = restarted();
    assert_eq!(
        tampered.adopt_runtime_workspaces(),
        [format!("{workspace_id}:revision")],
        "the wider scope measures another revision first"
    );
    assert_eq!(tampered.registration_project_ref(copy_ref), None);
    // Scopes that measure the same revision but not the recorded digest.
    fs::write(
        &manifest,
        original.replace(
            "\"Sources/App.txt\"\n  ]",
            "\"Sources/App.txt\",\n    \"Sources/Missing.txt\"\n  ]",
        ),
    )
    .unwrap();
    let rescoped = restarted();
    assert_eq!(
        rescoped.adopt_runtime_workspaces(),
        [format!("{workspace_id}:scopes")]
    );
    assert_eq!(rescoped.registration_project_ref(copy_ref), None);
    fs::write(&manifest, &original).unwrap();
    // A copy whose tree moved from its base is refused, never re-derived.
    let copied = evolution
        .join(workspace_id)
        .join("workspace/Sources/App.txt");
    fs::write(&copied, "edited outside any Job\n").unwrap();
    let drifted = restarted();
    assert_eq!(
        drifted.adopt_runtime_workspaces(),
        [format!("{workspace_id}:revision")]
    );
    assert_eq!(drifted.registration_project_ref(copy_ref), None);
    fs::write(&copied, "old\n").unwrap();
    assert_eq!(restarted().adopt_runtime_workspaces(), Vec::<String>::new());
}

/// Swift's copy: hidden entries copied, `.build` never, a `.git` pointer
/// file never, links kept only inside the tree and absolute ones rewritten
/// relative, modes kept for files and owner-only for directories.
#[test]
fn the_copy_keeps_swifts_exclusions_modes_and_links() {
    let root = Root::new("exclusions");
    let source = source_tree(&root);
    let file = |relative: &str, bytes: &str, mode: u32| {
        let path = source.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, bytes).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
    };
    file("Sources/.hidden", "hidden\n", 0o600);
    file("Sources/tool.sh", "#!/bin/sh\n", 0o750);
    file(".build/debug/cache", "cache\n", 0o644);
    file("Sources/Pkg/.build/cache", "nested cache\n", 0o644);
    file(".git", "gitdir: /elsewhere/.git/worktrees/x\n", 0o644);
    fs::create_dir_all(source.join("Sources/Deep")).unwrap();
    std::os::unix::fs::symlink("App.txt", source.join("Sources/relative-link")).unwrap();
    std::os::unix::fs::symlink(
        source.join("Sources/App.txt"),
        source.join("Sources/Deep/absolute-link"),
    )
    .unwrap();
    std::os::unix::fs::symlink(&source, source.join("Sources/root-link")).unwrap();
    let workspace = WorkspaceComposition::with_profiles(
        vec![oracle_profile(&source)],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap();
    let owners = Owners::new(root, workspace);
    // Hidden entries, links and `.build` are outside the revision; the
    // executable file is inside it.
    let inputs = json!({"projectRef": PROJECT,
        "expectedWorkspaceRevision": revision(&[("Sources/App.txt", b"old\n"),
            ("Sources/Other.txt", b"outside the narrowed scope\n"),
            ("Sources/tool.sh", b"#!/bin/sh\n")]),
        "allowedFileGlobs": ["Sources/App.txt"]});
    let (job, ran) = plan_and_run(&owners, inputs, "exclusions");
    assert_eq!(
        ran["result"]["state"],
        "succeeded",
        "{}",
        owners.record(&job)
    );
    let (workspace_id, _) = copy_of(&job, &isolated_revision());
    let copy = owners.evolution(&workspace_id).join("workspace");
    let expected: BTreeMap<String, String> = [
        ("Sources", "directory 700"),
        ("Sources/.hidden", "file 600 hidden\n"),
        ("Sources/App.txt", "file 644 old\n"),
        ("Sources/Deep", "directory 700"),
        ("Sources/Deep/absolute-link", "link ../App.txt"),
        ("Sources/Other.txt", "file 644 outside the narrowed scope\n"),
        ("Sources/Pkg", "directory 700"),
        ("Sources/relative-link", "link App.txt"),
        ("Sources/root-link", "link .."),
        ("Sources/tool.sh", "file 750 #!/bin/sh\n"),
    ]
    .into_iter()
    .map(|(path, kind)| (path.to_owned(), kind.to_owned()))
    .collect();
    assert_eq!(entries(&copy), expected);
    // A self-contained `.git` directory is copied by value, and the copy
    // measures the source's revision, HEAD and index included.
    let root = Root::new("git-directory");
    let source = source_tree(&root);
    fs::create_dir_all(source.join(".git/refs/heads")).unwrap();
    fs::write(source.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
    fs::write(
        source.join(".git/refs/heads/main"),
        format!("{}\n", "a".repeat(40)),
    )
    .unwrap();
    fs::write(source.join(".git/index"), "index bytes").unwrap();
    let workspace = WorkspaceComposition::with_profiles(
        vec![oracle_profile(&source)],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap();
    let owners = Owners::new(root, workspace);
    let head = format!(
        "profileVersion\t{PROFILE}\nhead\t{}\nindex\t{}\n",
        "a".repeat(40),
        sha256_hex(b"index bytes")
    );
    let with_git = |files: &[(&str, &[u8])]| {
        let mut material = head.clone();
        for (path, bytes) in files {
            material.push_str(&format!("file\t{path}\t{}\n", sha256_hex(bytes)));
        }
        sha256_hex(material.as_bytes())
    };
    let inputs = json!({"projectRef": PROJECT,
        "expectedWorkspaceRevision": with_git(&[("Sources/App.txt", b"old\n"),
            ("Sources/Other.txt", b"outside the narrowed scope\n")]),
        "allowedFileGlobs": ["Sources/App.txt"]});
    let (job, ran) = plan_and_run(&owners, inputs, "git-directory");
    assert_eq!(
        ran["result"]["state"],
        "succeeded",
        "{}",
        owners.record(&job)
    );
    let result = owners.result(&job);
    let copy_id = format!(
        "evo-{}",
        &sha256_hex(
            format!(
                "runtime-{job}|{PROJECT}|{}",
                with_git(&[("Sources/App.txt", b"old\n")])
            )
            .as_bytes()
        )[..24]
    );
    assert_eq!(result["result"]["terminal"], true);
    assert_eq!(
        fs::read_to_string(owners.evolution(&copy_id).join("workspace/.git/HEAD")).unwrap(),
        "ref: refs/heads/main\n"
    );
}

/// An entry the copy cannot keep fails the Job before any copy is
/// registered, and the refusal names the entry, never a host path.
#[test]
fn a_refused_entry_fails_the_job_naming_only_the_entry() {
    let root = Root::new("refusal");
    let source = source_tree(&root);
    let outside = root.join("outside");
    fs::create_dir(&outside).unwrap();
    fs::write(outside.join("secret.txt"), "secret\n").unwrap();
    std::os::unix::fs::symlink(
        outside.join("secret.txt"),
        source.join("Sources/external-link"),
    )
    .unwrap();
    std::os::unix::fs::symlink(
        "../../outside/secret.txt",
        source.join("Sources/relative-out"),
    )
    .unwrap();
    let workspace = WorkspaceComposition::with_profiles(
        vec![oracle_profile(&source)],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap();
    let owners = Owners::new(root, workspace);
    let (job, ran) = plan_and_run(&owners, oracle_inputs(), "refusal");
    assert_eq!(ran["result"]["state"], "failed", "{ran}");
    let (workspace_id, copy_ref) = copy_of(&job, &isolated_revision());
    let (workspace_id, copy_ref) = (workspace_id.as_str(), copy_ref.as_str());
    let record = owners.record(&job);
    let story = serde_json::to_string(&record).unwrap();
    assert!(
        story.contains(
            "workspace isolation refused: unsafeSourceEntry(\\\"Sources/external-link\\\")"
        ),
        "{story}"
    );
    for host in [
        text(&owners.root.0),
        "/private/var".into(),
        "/var/folders".into(),
    ] {
        assert!(!story.contains(&host), "{host} in {story}");
    }
    assert_eq!(record["operationFailure"]["code"], "executionFailed");
    assert!(record.get("recoveryAction").is_none());
    // The intent was durable and its failure correlated; no copy resolves.
    let timeline: Vec<String> = serde_json::from_value(record["timeline"].clone()).unwrap();
    let intent = timeline
        .iter()
        .position(|entry| entry == "intent prepare-isolated-copy")
        .unwrap();
    assert_eq!(timeline[intent + 1], "failed prepare-isolated-copy");
    assert_eq!(owners.workspace.registration_project_ref(copy_ref), None);
    let task = owners.evolution(workspace_id);
    assert!(!task.join(".workspace.tmp").exists());
    assert!(!task.join("workspace.json").exists());
    // The result reads the failed Job, whose product was never published.
    let result = owners.result(&job);
    assert_eq!(result["result"]["terminal"], true, "{result}");
    assert_eq!(
        result["result"]["evidence"]["terminalState"], "failed",
        "{result}"
    );
    assert_eq!(result["result"]["artifacts"], json!([]), "{result}");
}

/// A source that moved after admission is refused before the copy's intent
/// exists: Swift's run escapes there; this Runtime fails the Job with zero
/// dispatch rather than stranding it.
#[test]
fn a_source_that_moved_after_admission_fails_before_any_intent() {
    let owners = Owners::oracle("drift");
    let params = request(oracle_inputs(), "drift");
    let submitted = owners.submit(&params);
    let job = submitted["result"]["jobId"].as_str().unwrap().to_owned();
    fs::write(owners.root.join("source/Sources/Other.txt"), "moved\n").unwrap();
    let ran = owners.run(&job);
    assert_eq!(ran["result"]["state"], "failed", "{ran}");
    let record = owners.record(&job);
    let timeline: Vec<String> = serde_json::from_value(record["timeline"].clone()).unwrap();
    assert!(!timeline.iter().any(|entry| entry.starts_with("intent ")));
    assert!(
        timeline
            .iter()
            .any(|entry| entry.starts_with("reason: workspace.revisionConflict:59c1ac4a2252!=")),
        "{timeline:?}"
    );
    assert!(
        !owners
            .evolution(&copy_of(&job, &isolated_revision()).0)
            .exists()
    );
    // A plan against the moved tree is refused the same way.
    let plan = owners.plan(&params);
    assert_eq!(plan["error"]["code"], "invalidInput");
    assert!(
        plan["error"]["message"].as_str().unwrap().starts_with(
            "typed plan preflight failed before authorization: workspace.revisionConflict:"
        ),
        "{plan}"
    );
}

/// Swift's provider rules at plan time: a scope wider than the profile's,
/// a copy asked to copy itself, and a request that pins a device binding.
#[test]
fn plans_are_refused_by_swifts_provider_rules() {
    let owners = Owners::oracle("provider-rules");
    let refused = |inputs: Value| -> String {
        let answer = owners.plan(&request(inputs, "rules"));
        assert_eq!(answer["ok"], false, "{answer}");
        answer["error"]["message"].as_str().unwrap().to_owned()
    };
    assert_eq!(
        refused(
            json!({"projectRef": PROJECT, "expectedWorkspaceRevision": source_revision(),
            "allowedFileGlobs": ["Other/**"]})
        ),
        "typed plan preflight failed before authorization: \
         workspace.isolationScopeOutsideProjectProfile"
    );
    assert_eq!(
        refused(
            json!({"projectRef": "Unknown", "expectedWorkspaceRevision": source_revision(),
            "allowedFileGlobs": ["Sources/App.txt"]})
        ),
        "typed plan preflight failed before authorization: \
         workspace.projectProfileUnavailable:Unknown"
    );
    let (job, ran) = plan_and_run(&owners, oracle_inputs(), "copy-first");
    assert_eq!(ran["result"]["state"], "succeeded");
    assert_eq!(
        refused(json!({"projectRef": copy_of(&job, &isolated_revision()).1,
            "expectedWorkspaceRevision": revision(&[("Sources/App.txt", b"old\n")]),
            "allowedFileGlobs": ["Sources/App.txt"]})),
        "typed plan preflight failed before authorization: workspace.presetUnavailable",
        "a Runtime-owned copy is never copied again"
    );
    let mut pinned: Value = serde_json::from_str(
        request(oracle_inputs(), "pinned")["requestJson"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    pinned["target"]["expectedBindingRevision"] = json!(1);
    let answer = owners.plan(&json!({"requestJson": pinned.to_string()}));
    assert_eq!(
        answer["error"]["message"],
        "workspace.prepare-isolated-copy@1 is host-only: a request must not pin a binding revision"
    );
    // No provider composed: Swift's unregistered provider.
    let bare = JobPlanner {
        workspace: None,
        ..owners.planner()
    };
    let refusal = bare
        .handle(request(oracle_inputs(), "bare").as_object().unwrap())
        .unwrap_err();
    assert_eq!(refusal.message, "provider workspace is not registered");
}

/// The production composition over the registration owner: a registered
/// project resolves to its kind's profile, a Job acquires its registration
/// while it is materialized, a project registered since the Runtime started
/// is refused until it restarts, and the restarted Runtime adopts the copy.
#[test]
fn a_registered_project_is_copied_and_its_copy_adopted_after_restart() {
    let root = Root::new("registered");
    let project = root.join("project");
    for marker in ["build-profile.json5", "entry/src/main/module.json5"] {
        fs::create_dir_all(project.join(marker).parent().unwrap()).unwrap();
        fs::write(project.join(marker), "{}\n").unwrap();
    }
    fs::create_dir_all(project.join("entry/src/main/ets/pages")).unwrap();
    fs::write(project.join("entry/src/main/ets/pages/Index.ets"), "old\n").unwrap();
    fs::write(project.join("entry/src/main/ets/Other.ets"), "other\n").unwrap();
    fs::create_dir(root.join("workspace-projects")).unwrap();
    fs::set_permissions(
        root.join("workspace-projects"),
        fs::Permissions::from_mode(0o700),
    )
    .unwrap();
    let projects = Arc::new(WorkspaceProjectStore::open(&root.join("workspace-projects")).unwrap());
    let census = |_: arkdeck_hoststore::WorkspaceReference<'_>| Ok(());
    let register = |request: &str, root: &Path| {
        projects
            .handle(
                "workspace.project.register",
                json!({"registrationRequestId": request, "kind": "openharmony",
                    "root": text(root)})
                .as_object()
                .unwrap(),
                &|| TIMESTAMP.to_owned(),
                &census,
            )
            .unwrap()["projectRef"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let registered = register("registration-before-start", &project);
    let (workspace, unadopted) = WorkspaceComposition::compose(
        Arc::clone(&projects),
        &root.0,
        "/nonexistent-home",
        oracle_now,
    )
    .unwrap();
    assert!(unadopted.is_empty());
    let owners = Owners::new(root, workspace);
    let profile_revision = |files: &[(&str, &[u8])]| {
        let mut material =
            "profileVersion\twaterflow-openharmony@1\nhead\tabsent\nindex\tabsent\n".to_owned();
        for (path, bytes) in files {
            material.push_str(&format!("file\t{path}\t{}\n", sha256_hex(bytes)));
        }
        sha256_hex(material.as_bytes())
    };
    let inputs = json!({"projectRef": registered,
        "expectedWorkspaceRevision": profile_revision(&[
            ("entry/src/main/ets/Other.ets", b"other\n"),
            ("entry/src/main/ets/pages/Index.ets", b"old\n")]),
        "allowedFileGlobs": ["entry/src/main/ets/pages/**"]});
    // While a Job holds the registration, the project can be neither
    // updated nor removed.
    let held = projects.acquire_use(&registered, &[]).unwrap();
    let removal = projects
        .handle(
            "workspace.project.remove",
            json!({"projectRef": registered, "expectedGeneration": "1"})
                .as_object()
                .unwrap(),
            &|| TIMESTAMP.to_owned(),
            &census,
        )
        .unwrap_err();
    assert_eq!(removal.code, "resourceConflict");
    assert_eq!(
        removal.message,
        "workspace project is being materialized by a Job"
    );
    drop(held);
    let (job, ran) = plan_and_run(&owners, inputs.clone(), "registered");
    assert_eq!(
        ran["result"]["state"],
        "succeeded",
        "{}",
        owners.record(&job)
    );
    let result = owners.result(&job);
    let artifact = &result["result"]["artifacts"][0];
    assert_eq!(artifact["name"], "isolated-workspace.json");
    // A project registered after the Runtime started is not composed.
    let second = owners.root.join("second");
    fs::create_dir(&second).unwrap();
    let later = register("registration-after-start", &second);
    let late = owners.plan(&request(
        json!({"projectRef": later, "expectedWorkspaceRevision": "0".repeat(64),
            "allowedFileGlobs": ["entry/src/main/ets/pages/**"]}),
        "late",
    ));
    assert_eq!(late["error"]["code"], "operationUnavailable", "{late}");
    assert_eq!(
        late["error"]["message"],
        "workspace project configuration changed; restart the Runtime before submitting a Job"
    );
    // The restarted Runtime composes both and adopts the copy.
    let (restarted, unadopted) = WorkspaceComposition::compose(
        Arc::clone(&projects),
        &owners.root.0,
        "/nonexistent-home",
        oracle_now,
    )
    .unwrap();
    assert!(unadopted.is_empty(), "{unadopted:?}");
    let evolution: Vec<String> = fs::read_dir(owners.root.join("evolution-workspaces"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(evolution.len(), 1);
    let manifest: Value = serde_json::from_slice(
        &fs::read(
            owners
                .root
                .join("evolution-workspaces")
                .join(&evolution[0])
                .join("workspace.json"),
        )
        .unwrap(),
    )
    .unwrap();
    let copy = manifest["workspace"]["projectRef"].as_str().unwrap();
    assert_eq!(
        restarted.registration_project_ref(copy).as_deref(),
        Some(registered.as_str())
    );
    assert_eq!(
        owners.workspace.registration_project_ref(copy).as_deref(),
        Some(registered.as_str())
    );
}
