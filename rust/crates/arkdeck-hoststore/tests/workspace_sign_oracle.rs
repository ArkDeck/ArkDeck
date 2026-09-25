//! Replays the Swift `workspace.sign-openharmony-hap@1` oracle
//! (`rust/tests/fixtures/workspace-sign-oracle`, recorded by
//! `WorkspaceSignOracleContractTests`) against the Rust planner, admitter,
//! runner, reconciler and result reader over the same fixed root, receipt,
//! stand-in signer, fake passwords and clock: every answer must be Swift's
//! (the plan's additive review digest aside), and what the Runtime keeps —
//! the published signed HAPs and reports, the credential owner's ledger and
//! the durable record of each Job parked on an unknown outcome — Swift's byte
//! for byte.
//!
//! The acceptance for signing is the restated SPK-10 criterion (Q9): the
//! argv, the terminal prompt protocol, the signing identity and the
//! verification readbacks, never the signed bytes of a real signer, which
//! differ on every run. Here the stand-in's bytes are fixed, so the products
//! compare too. The same binary pins what the recording does not: neither
//! password reaches any file, record, receipt or log below the root; a
//! verification that cannot be read back is never trusted; a parked Job is
//! never signed again; and a drifted signing file refuses the dispatch
//! before the signer runs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, JobAdmitter, JobPlanner, JobReconciler,
    JobResultReader, JobRunner, JobStore, MutationAuthority, MutationExecution, ProfilePresets,
    ResolvedToolchain, SigningPresetRef, SigningSetup, WorkspaceCommandPreset,
    WorkspaceComposition, WorkspaceProfile, WorkspaceProjectStore, WorkspaceToolchainPinning,
    credential_pinning,
};
use arkdeck_platform::Secret;
use arkdeck_provider_workspace::SigningError;
use arkdeck_provider_workspace::credential_owner::CredentialOwner;
use arkdeck_provider_workspace::secret_envelope::encode_envelope;
use arkdeck_provider_workspace::signing_preset::{
    SecretPresence, SigningPresetStore, SigningSecrets,
};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use support::chmod;

const ROOT: &str = "/private/tmp/arkdeck-workspace-sign-oracle";
/// Foundation's spelling of the root, which the receipt, the attempt store
/// and the lowered argv name.
const FOUNDATION: &str = "/tmp/arkdeck-workspace-sign-oracle";
const LOCK: &str = "/private/tmp/arkdeck-workspace-sign-oracle.lock";
const TIMESTAMP: &str = "2026-09-25T00:00:00Z";
const PROJECT: &str = "SignOracleProject";
const PROFILE: &str = "workspace-sign-oracle@1";
const PRESET: &str = "preset-signing-oracle";
const ENVELOPE: &str = "openharmony-release@1|secret-envelope-5d3c1f0e-7a2b-4c9d-8e6f-0a1b2c3d4e5f";
/// The recording's fake passwords: nothing they unlock exists anywhere.
const KEYSTORE_SECRET: &str = "oracle-keystore-password-7f3a";
const KEY_SECRET: &str = "oracle-key-password-2c9e";

fn oracle_now() -> Option<String> {
    Some(TIMESTAMP.into())
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

/// The oracle's Keychain: the envelope holding both fake passwords, in
/// memory, under the receipt's account.
struct OracleSecrets(Mutex<BTreeMap<String, Vec<u8>>>);

impl OracleSecrets {
    fn installed() -> Self {
        let envelope = encode_envelope(KEYSTORE_SECRET.as_bytes(), KEY_SECRET.as_bytes());
        Self(Mutex::new(BTreeMap::from([(
            ENVELOPE.to_owned(),
            envelope.as_bytes().to_vec(),
        )])))
    }
}

impl SigningSecrets for OracleSecrets {
    fn read(&self, account: &str) -> Result<Secret, SigningError> {
        self.0
            .lock()
            .unwrap()
            .get(account)
            .map(|bytes| Secret::from_slice(bytes))
            .ok_or_else(|| SigningError::SecretUnavailable("missing oracle secret".into()))
    }
    fn presence(&self, account: &str) -> SecretPresence {
        if self.0.lock().unwrap().contains_key(account) {
            SecretPresence::Present
        } else {
            SecretPresence::Absent
        }
    }
    fn trusted_daemon_fingerprint(&self) -> Result<Option<String>, SigningError> {
        Ok(None)
    }
}

/// A private root, removed when the test ends.
struct Root(PathBuf);

impl Root {
    fn fixed() -> Self {
        let root = PathBuf::from(ROOT);
        let _ = fs::remove_dir_all(&root);
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

fn write(path: &Path, bytes: &[u8], mode: u32) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, bytes).unwrap();
    chmod(path, mode);
}

/// The installed preset, the project source and the five published inputs,
/// each as the Swift recording left them before its first request.
fn seed(root: &Root, fixture: &Path) {
    write(
        &root.join("tools/java"),
        &fs::read(fixture.join("hap-signer.sh")).unwrap(),
        0o755,
    );
    for (name, bytes, mode) in [
        (
            "material/hap-sign-tool.jar",
            "oracle hap-sign-tool\n",
            0o644,
        ),
        ("material/release.p12", "oracle keystore\n", 0o600),
        ("material/release.cer", "oracle certificate\n", 0o644),
        ("material/release.p7b", "oracle profile\n", 0o644),
        (
            "source/entry/src/main/ets/pages/Index.ets",
            "struct Index {}\n",
            0o644,
        ),
    ] {
        write(&root.join(name), bytes.as_bytes(), mode);
    }
    fs::create_dir(root.join("preset")).unwrap();
    chmod(&root.join("preset"), 0o700);
    write(
        &root.join("preset/preset-v1.json"),
        &fs::read(fixture.join("preset-v1.json")).unwrap(),
        0o600,
    );
    let inputs = root.join("artifacts/job-input-hap");
    fs::create_dir(&inputs).unwrap();
    chmod(&inputs, 0o700);
    for file in fs::read_dir(fixture.join("artifacts/job-input-hap")).unwrap() {
        let file = file.unwrap().path();
        let name = file.file_name().unwrap();
        fs::copy(&file, inputs.join(name)).unwrap();
        chmod(
            &inputs.join(name),
            if name == "index.json" { 0o600 } else { 0o400 },
        );
    }
}

struct Owners {
    root: Root,
    jobs: JobStore,
    artifacts: ArtifactReadStore,
    capabilities: CapabilityStore,
    holds: DeviceHolds,
    workspace: WorkspaceComposition,
}

impl Owners {
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
    fn runner<'a>(&'a self, default_root: &'a Path) -> JobRunner<'a> {
        JobRunner {
            mutation: Some(MutationExecution {
                authority: self.authority(default_root),
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
        match self
            .runner(&default_root)
            .handle(json!({"jobId": job}).as_object().unwrap())
        {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(refusal) => refused(refusal.code, &refusal.message, Some(refusal.details)),
        }
    }
    fn reconcile(&self, job: &str) -> Value {
        let default_root = self.default_root();
        let runner = self.runner(&default_root);
        let reconciler = JobReconciler {
            jobs: &self.jobs,
            artifacts: &self.artifacts,
            imports: None,
            now: oracle_now,
            sessions: None,
            hdc: None,
            capabilities: Some(&self.capabilities),
            runner: Some(&runner),
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

fn request_id(params: &Value) -> Option<String> {
    let document: Value = serde_json::from_str(params["requestJson"].as_str()?).ok()?;
    document["requestId"].as_str().map(str::to_owned)
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

/// Every regular file below `root`.
fn every_file(root: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).unwrap() {
            let path = entry.unwrap().path();
            let kind = fs::symlink_metadata(&path).unwrap().file_type();
            if kind.is_dir() {
                pending.push(path);
            } else if kind.is_file() {
                found.push(path);
            }
        }
    }
    found
}

/// Neither fake password appears anywhere in `bytes`.
fn secret_free(what: &str, bytes: &[u8]) {
    for secret in [KEYSTORE_SECRET, KEY_SECRET] {
        assert!(
            !bytes
                .windows(secret.len())
                .any(|window| window == secret.as_bytes()),
            "a password reached {what}"
        );
    }
}

/// The recording's Runtime over the fixed root: the signing preset the
/// workspace preset pins through the credential owner, the only registered
/// preset of the profile, no fallback to the installed receipt.
fn owners(root: Root) -> Owners {
    let store = SigningPresetStore::new(format!("{FOUNDATION}/preset"));
    let owner = CredentialOwner::new(store);
    let credential = owner.current().unwrap().credential_ref;
    owner
        .acquire(&credential, PRESET, &OracleSecrets::installed())
        .unwrap();
    let preset =
        |id: &str| WorkspaceCommandPreset::hashing(id, "/usr/bin/grep", None, &[], 10).unwrap();
    let profile = WorkspaceProfile::primary(
        PROFILE,
        PROJECT,
        &format!("{FOUNDATION}/source"),
        &["entry/src/main/ets/**"],
        preset("inspect"),
        preset("patch"),
        ProfilePresets::default(),
    )
    .unwrap()
    .with_signing(
        vec![SigningPresetRef::new(PRESET, &credential, 600).unwrap()],
        false,
    );
    let workspace = WorkspaceComposition::with_profiles(
        vec![profile],
        &root.join("evolution-workspaces"),
        oracle_now,
    )
    .unwrap()
    .with_signing(
        Path::new(&format!("{FOUNDATION}/preset")),
        Box::new(OracleSecrets::installed()),
        Path::new(&format!("{FOUNDATION}/signing-attempts")),
    )
    .unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let capabilities = CapabilityStore::open(&root.join("jobs-state/capabilities")).unwrap();
    Owners {
        jobs,
        artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
        capabilities,
        holds: DeviceHolds::default(),
        workspace,
        root,
    }
}

#[test]
fn the_rust_runtime_answers_the_recorded_signing_sequence() {
    let _held = exclusive();
    let fixture = support::fixture("workspace-sign-oracle");
    let provenance = support::document(&fixture, "provenance.json");
    for (name, digest) in provenance["files"].as_object().unwrap() {
        assert_eq!(
            sha256_hex(&fs::read(fixture.join(name)).unwrap()),
            digest.as_str().unwrap(),
            "{name} is the recorded file"
        );
    }
    let root = Root::fixed();
    seed(&root, &fixture);
    let owners = owners(root);
    // The credential owner's ledger is Swift's once the preset pinned it.
    assert_eq!(
        fs::read(owners.root.join("preset/credential-owner-v1.json")).unwrap(),
        fs::read(fixture.join("credential-owner-v1.json")).unwrap()
    );
    let frames: Vec<Value> = fs::read_to_string(fixture.join("frames.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(frames.len(), 19);
    let mut jobs: BTreeMap<String, String> = BTreeMap::new();
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
            "job.run" => owners.run(params["jobId"].as_str().unwrap()),
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
        // The durable record of each Job parked on an unknown outcome, as
        // Swift's was before its reconcile: the exact typed action it
        // persisted, and its story.
        if method == "job.run" && answer["result"]["state"] == "waitingForRecovery" {
            let job = params["jobId"].as_str().unwrap();
            let name = match label.as_str() {
                "request-rejected" => Some("rejected-parked-record.json"),
                "request-verify-once" => Some("verify-once-parked-record.json"),
                _ => None,
            };
            if let Some(name) = name {
                assert_eq!(
                    owners.record(job),
                    support::document(&fixture, name),
                    "{name}"
                );
            }
            // A parked Job is never signed again: running it once more is
            // refused before anything is dispatched or written.
            let before = owners.record(job);
            assert_eq!(
                owners.run(job),
                refused(
                    "resourceConflict",
                    &format!("job {job} is waitingForRecovery, not runnable"),
                    Some(proven())
                ),
                "{label}"
            );
            assert_eq!(owners.record(job), before, "{label}");
        }
    }
    // The signed and the recovered Jobs' products, byte for byte.
    for job in fs::read_dir(fixture.join("artifacts")).unwrap() {
        let job = job.unwrap().file_name().into_string().unwrap();
        if job == "job-input-hap" {
            continue;
        }
        assert_eq!(
            files(&owners.root.join("artifacts").join(&job), "ART-"),
            files(&fixture.join("artifacts").join(&job), "ART-"),
            "{job}'s published products"
        );
    }
    // The ledger is unchanged by every resolution since.
    assert_eq!(
        fs::read(owners.root.join("preset/credential-owner-v1.json")).unwrap(),
        fs::read(fixture.join("credential-owner-v1.json")).unwrap()
    );
    // A signing file that drifts after admission refuses the dispatch before
    // the signer runs: the Job fails with its outcome known, nothing signed.
    let drifted = json!({"requestJson": json!({
        "documentType": "runtime-operation-request",
        "idempotencyKey": "idempotency-drift",
        "inputs": {"projectRef": PROJECT, "signingPresetRef": PRESET,
                   "unsignedHapArtifactLease":
                       "lease-v1:job-input-hap:ART-81ae19b19ca7ea0d3ce99c554182c815"},
        "operation": {"id": "workspace.sign-openharmony-hap", "version": 1},
        "requestId": "request-drift",
        "requestedOutputs": ["derivedArtifacts"],
        "schemaVersion": "1.0.0",
        "target": {"targetId": "workspace-host"},
    }).to_string()});
    let accepted = owners.submit(&drifted);
    let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
    write(
        &owners.root.join("material/release.cer"),
        b"a certificate the receipt never pinned\n",
        0o644,
    );
    let run = owners.run(&job);
    let record = owners.record(&job);
    assert_eq!(record["state"], "failed", "{run}");
    assert_eq!(record["outcomeUnknown"], false, "{record}");
    // Refused when the step is lowered again — the preset no longer
    // validates — before any intent, so the signer never ran.
    let timeline: Vec<&str> = record["timeline"]
        .as_array()
        .unwrap()
        .iter()
        .map(|line| line.as_str().unwrap())
        .collect();
    assert!(
        timeline.contains(&"reason: workspace.presetUnavailable"),
        "{timeline:?}"
    );
    assert!(
        !timeline.iter().any(|line| line.starts_with("intent ")),
        "{timeline:?}"
    );
    assert!(
        !every_file(&owners.root.join("artifacts"))
            .iter()
            .any(
                |path| path.starts_with(owners.root.join("artifacts").join(&job))
                    && path
                        .file_name()
                        .is_some_and(|name| name.to_string_lossy().starts_with("ART-"))
            ),
        "nothing was published for {job}"
    );
    // Every attempt directory is gone once its Job is terminal.
    assert_eq!(
        fs::read_dir(owners.root.join("signing-attempts"))
            .unwrap()
            .count(),
        0
    );
    // No password reached any file the Runtime keeps: records, journals,
    // Artifacts, the ledger, the attempt store.
    let every = every_file(&owners.root.0);
    assert!(every.len() > 20, "the scan read the run's files");
    for path in every {
        secret_free(&path.display().to_string(), &fs::read(&path).unwrap());
    }
}

fn ledger_owners(root: &Root) -> Value {
    let ledger: Value =
        serde_json::from_slice(&fs::read(root.join("preset/credential-owner-v1.json")).unwrap())
            .unwrap();
    ledger["presetOwners"].clone()
}

/// The production composition of a registered signing preset. Registering
/// it pins the credential through the owner's ledger — refused, before the
/// store writes anything, for a credential bound to another project. After a
/// restart the preset composes through its toolchain pin and its credential,
/// pinned by it, secrets present, into its project's profile, which signs
/// with it; the owner releases at start-up a pin no preset record carries.
/// Without the credential owner the same preset stays unresolved and nothing
/// is signed. Removing the preset releases its pin.
#[test]
fn a_registered_signing_preset_pins_its_credential_and_signs_after_a_restart() {
    let _held = exclusive();
    let fixture = support::fixture("workspace-sign-oracle");
    let root = Root::fixed();
    seed(&root, &fixture);
    for tree in ["source", "other"] {
        write(
            &root.join(&format!("{tree}/build-profile.json5")),
            b"{}\n",
            0o644,
        );
        write(
            &root.join(&format!("{tree}/entry/src/main/module.json5")),
            b"{}\n",
            0o644,
        );
    }
    fs::create_dir(root.join("workspace-projects")).unwrap();
    chmod(&root.join("workspace-projects"), 0o700);
    let store = PathBuf::from(format!("{FOUNDATION}/preset"));
    let projects = Arc::new(
        WorkspaceProjectStore::open(&root.join("workspace-projects"))
            .unwrap()
            .with_dependency_pinning(
                Some(WorkspaceToolchainPinning {
                    acquire: Box::new(|_, _, _| Ok(())),
                    release: Box::new(|_, _| Ok(())),
                }),
                Some(credential_pinning(
                    store.clone(),
                    Box::new(OracleSecrets::installed()),
                )),
            ),
    );
    let call = |method: &str, params: Value| {
        projects.handle(
            method,
            params.as_object().unwrap(),
            &|| "2026-09-25T00:00:00.000Z".into(),
            &|_| Ok(()),
        )
    };
    let register = |request: &str, tree: &str| {
        call(
            "workspace.project.register",
            json!({"registrationRequestId": request, "kind": "openharmony",
                   "root": format!("{ROOT}/{tree}")}),
        )
        .unwrap()["projectRef"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let project = register("project", "source");
    let other = register("other", "other");
    // The installed receipt binds the credential to the registered project.
    let receipt = fs::read_to_string(root.join("preset/preset-v1.json")).unwrap();
    write(
        &root.join("preset/preset-v1.json"),
        receipt
            .replace("\"SignOracleProject\"", &format!("\"{project}\""))
            .as_bytes(),
        0o600,
    );
    let owner = CredentialOwner::new(SigningPresetStore::new(&store));
    let credential = owner.current().unwrap().credential_ref;
    let signing = |request: &str, project: &str| {
        call(
            "workspace.preset.register",
            json!({"registrationRequestId": request, "projectRef": project, "kind": "signing",
                   "templateRef": "openharmony.local-sign@1", "timeoutSeconds": "600",
                   "toolchainRef": format!("toolchain:sha256:{}", "a".repeat(64)),
                   "toolchainGeneration": "1", "credentialRef": credential}),
        )
    };
    // Another project's preset may not pin this credential; nothing is
    // written, so the store keeps answering.
    let foreign = signing("foreign", &other).unwrap_err();
    assert_eq!(
        (foreign.code.as_str(), foreign.message.as_str()),
        (
            "resourceConflict",
            format!("signing credential {credential} is bound to project {project}, not {other}")
                .as_str()
        )
    );
    assert_eq!(
        call("workspace.preset.list", json!({"projectRef": other})).unwrap()["presets"],
        json!([])
    );
    assert_eq!(ledger_owners(&root), json!([]));
    let preset = signing("signing", &project).unwrap()["presetRef"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(ledger_owners(&root), json!([preset]));
    // A pin a retired state directory left behind.
    owner
        .acquire(&credential, "preset-retired", &OracleSecrets::installed())
        .unwrap();
    let toolchains = |_: &str, _: u64, _: &str| {
        Ok(ResolvedToolchain {
            node_path: "/usr/bin/true".into(),
            hvigor_script_path: "/usr/bin/true".into(),
            sdk_root_path: "/usr".into(),
            verified_resources: Vec::new(),
        })
    };
    let request = |label: &str| {
        json!({"requestJson": json!({
            "documentType": "runtime-operation-request",
            "idempotencyKey": format!("idempotency-{label}"),
            "inputs": {"projectRef": project, "signingPresetRef": preset,
                       "unsignedHapArtifactLease":
                           "lease-v1:job-input-hap:ART-81ae19b19ca7ea0d3ce99c554182c815"},
            "operation": {"id": "workspace.sign-openharmony-hap", "version": 1},
            "requestId": format!("request-{label}"),
            "requestedOutputs": ["derivedArtifacts"],
            "schemaVersion": "1.0.0",
            "target": {"targetId": "workspace-host"},
        }).to_string()})
    };
    // Without the credential owner the preset resolves to nothing, so it is
    // never applied and a Job naming it is refused as Swift refuses it.
    let (unsigned, notes) = WorkspaceComposition::compose(
        Arc::clone(&projects),
        &root.0,
        "/nonexistent-home",
        oracle_now,
        &toolchains,
        None,
        None,
    )
    .unwrap();
    assert_eq!(notes.released_credential_owners, None);
    let owners = Owners {
        jobs: JobStore::open_owner(&root.join("jobs-state")).unwrap(),
        artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
        capabilities: CapabilityStore::open(&root.join("jobs-state/capabilities")).unwrap(),
        holds: DeviceHolds::default(),
        workspace: unsigned,
        root,
    };
    let answer = owners.plan(&request("unsigned"));
    assert_eq!(
        answer,
        refused(
            "operationUnavailable",
            "workspace preset configuration changed; restart the Runtime before submitting a Job",
            Some(proven())
        )
    );
    assert_eq!(
        ledger_owners(&owners.root),
        json!([preset.as_str(), "preset-retired"])
    );
    // The restarted Runtime owns the default state directory.
    let (signed, notes) = WorkspaceComposition::compose(
        Arc::clone(&projects),
        &owners.root.0,
        "/nonexistent-home",
        oracle_now,
        &toolchains,
        Some(
            SigningSetup::with_secrets(
                store.clone(),
                PathBuf::from(format!("{FOUNDATION}/signing-attempts")),
                Box::new(OracleSecrets::installed()),
            )
            .releasing_orphaned_owners(),
        ),
        None,
    )
    .unwrap();
    assert_eq!(
        notes.released_credential_owners,
        Some(Ok(vec!["preset-retired".to_owned()]))
    );
    assert!(notes.unadopted.is_empty());
    assert_eq!(ledger_owners(&owners.root), json!([preset]));
    let owners = Owners {
        workspace: signed,
        ..owners
    };
    assert_eq!(owners.plan(&request("sign"))["ok"], true);
    let accepted = owners.submit(&request("sign"));
    let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
    let run = owners.run(&job);
    assert_eq!(run["result"]["state"], "succeeded", "{run}");
    let result = owners.result(&job);
    let names: Vec<&str> = result["result"]["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|artifact| artifact["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["signed.hap", "signing-report.json"], "{result}");
    assert_eq!(
        fs::read_dir(owners.root.join("signing-attempts"))
            .unwrap()
            .count(),
        0
    );
    // Removing the preset releases its pin.
    call(
        "workspace.preset.remove",
        json!({"mutationRequestId": "remove", "projectRef": project,
               "presetRef": preset, "expectedGeneration": "1"}),
    )
    .unwrap();
    assert_eq!(ledger_owners(&owners.root), json!([]));
    for path in every_file(&owners.root.0) {
        secret_free(&path.display().to_string(), &fs::read(&path).unwrap());
    }
}
