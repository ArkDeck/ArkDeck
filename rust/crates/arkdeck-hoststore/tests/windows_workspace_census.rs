//! The Job owner's workspace project and preset census on the Windows Job
//! store (TASK-XPA-005/015): the census a `workspace.project.update|remove`
//! and `workspace.preset.update|remove` consults before it writes.
//!
//! The Job is Swift's: the recorded `workspace.prepare-isolated-copy@1` Job
//! of `rust/tests/fixtures/agent-execution-evidence`, admitted into a
//! private `jobs-state` on NTFS by the Job store owner under its request's
//! own fingerprint, with only what the census reads changed — the project
//! it names, a preset input, its state or outcome, and, where a preset is
//! to be read, the Catalog it was admitted under. Then, as on macOS:
//! an active or uncertain workspace Job naming the project or the preset
//! refuses its mutation (`resourceConflict`, no new dispatch); a terminal
//! one, or one naming another project or preset, refuses nothing; and a
//! record the census cannot verify refuses every mutation
//! (`recordUnreadable`). A Job of this build's Catalog names a preset only
//! through its operation's own preset inputs, which the recorded operation
//! has none of; a Job admitted under another Catalog is read by every
//! closed preset input name, so the preset cases use one. Each answer is
//! read again from a reopened store.
#![cfg(windows)]

use arkdeck_hoststore::{AdmissionVerdict, JobRecord, JobStore, OperationRequest};
use arkdeck_platform::HostDirectory;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

const JOB: &str = "job-863e9a9bd1d60afe3c33ac9e43a7b7fb";
const PROJECT: &str = "project-bfc6409a3cc9d14ba4355fe0";
const PRESET: &str = "preset-2f0c61c1a0d7f1f4a8b6";
/// A Catalog digest that is not this build's.
const OLDER_CATALOG: &str = "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f";

fn recorded() -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../../tests/fixtures/agent-execution-evidence/store/jobs/{JOB}/job-record.json"
    ));
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

/// Swift's workspace Job naming `project` and, as its build preset,
/// `preset`, in `state`; its outcome unknown when `uncertain`; admitted
/// under another Catalog when `older`. Its request hash is the changed
/// request's own fingerprint, as admission computes it.
fn workspace_job(
    project: &str,
    preset: &str,
    state: &str,
    uncertain: bool,
    older: bool,
) -> (JobRecord, String) {
    let mut record = recorded();
    record["catalogDigest"] = json!(if older {
        OLDER_CATALOG
    } else {
        arkdeck_contract::CATALOG_DIGEST
    });
    for request in ["request", "originalSubmissionRequest"] {
        let inputs = &mut record[request]["inputs"];
        inputs["projectRef"] = json!(project);
        inputs["buildPresetRef"] = json!(preset);
    }
    record["state"] = json!(state);
    record["outcomeUnknown"] = json!(uncertain);
    let hash = OperationRequest::decode(
        &serde_json::to_vec(&record["originalSubmissionRequest"]).unwrap(),
    )
    .unwrap()
    .fingerprint();
    let record = JobRecord::decode(&serde_json::to_vec_pretty(&record).unwrap()).unwrap();
    (record, hash)
}

/// A fresh private `jobs-state` below the temporary directory, removed
/// afterwards.
struct State(PathBuf);
impl State {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-wincensus-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        let state = Self(path);
        HostDirectory::open_or_create_private(&state.jobs()).unwrap();
        state
    }
    fn jobs(&self) -> PathBuf {
        self.0.join("jobs-state")
    }
    fn admitted(
        &self,
        project: &str,
        preset: &str,
        state: &str,
        uncertain: bool,
        older: bool,
    ) -> JobStore {
        let (record, hash) = workspace_job(project, preset, state, uncertain, older);
        self.admitted_as(&record, &hash)
    }
    fn admitted_as(&self, record: &JobRecord, hash: &str) -> JobStore {
        let store = JobStore::open_owner(&self.jobs()).unwrap();
        assert_eq!(
            store.admit(record, hash).unwrap(),
            AdmissionVerdict::Admitted
        );
        store
    }
}
impl Drop for State {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The census's answer for the project and the preset, from the owner and
/// then, the owner closed, from a store reopened over the same directory:
/// `None` when it refuses nothing, else the code.
fn census(state: &State, store: JobStore) -> [(Option<String>, Option<String>); 2] {
    let answer = |store: &JobStore| {
        let project = store
            .require_no_active_workspace_project_reference(PROJECT, &|_| None)
            .err();
        let preset = store
            .require_no_active_workspace_preset_reference(PRESET)
            .err();
        for (error, phase, message) in [
            (&project, "workspaceProjectOwner", "workspace project"),
            (&preset, "workspacePresetOwner", "workspace preset"),
        ] {
            if let Some(error) = error {
                assert_eq!(
                    error
                        .details
                        .as_ref()
                        .map(|details| Value::Object(details.clone())),
                    Some(json!({"phase": phase, "newDispatchCount": 0})),
                    "{}",
                    error.message
                );
                if error.code == "resourceConflict" {
                    assert_eq!(
                        error.message,
                        format!("{message} is referenced by an active or uncertain Job")
                    );
                }
            }
        }
        (
            project.map(|error| error.code),
            preset.map(|error| error.code),
        )
    };
    let first = answer(&store);
    drop(store);
    let reopened = JobStore::open(&state.jobs()).unwrap();
    [first, answer(&reopened)]
}

fn conflict() -> Option<String> {
    Some("resourceConflict".into())
}

#[test]
fn an_active_or_uncertain_workspace_job_refuses_its_project_and_preset() {
    for (job_state, uncertain) in [
        ("running", false),
        ("waitingForRecovery", false),
        ("succeeded", true),
    ] {
        let state = State::new();
        let store = state.admitted(PROJECT, PRESET, job_state, uncertain, true);
        assert_eq!(
            census(&state, store),
            [(conflict(), conflict()), (conflict(), conflict())],
            "{job_state}, uncertain {uncertain}"
        );
        // Under this build's Catalog the operation has no preset input: its
        // project is held, a preset named outside its inputs is not.
        let state = State::new();
        let store = state.admitted(PROJECT, PRESET, job_state, uncertain, false);
        assert_eq!(
            census(&state, store),
            [(conflict(), None), (conflict(), None)],
            "{job_state}, uncertain {uncertain}"
        );
    }
}

#[test]
fn a_terminal_job_or_one_naming_another_project_refuses_nothing() {
    for older in [false, true] {
        let state = State::new();
        let store = state.admitted(PROJECT, PRESET, "succeeded", false, older);
        assert_eq!(census(&state, store), [(None, None), (None, None)]);

        let state = State::new();
        let store = state.admitted("project-another", "preset-another", "running", false, older);
        assert_eq!(census(&state, store), [(None, None), (None, None)]);
    }
    // No Job at all.
    let state = State::new();
    let store = JobStore::open_owner(&state.jobs()).unwrap();
    assert_eq!(census(&state, store), [(None, None), (None, None)]);
}

/// A running Job becomes terminal: what it refused, it refuses no longer.
#[test]
fn a_job_that_ends_releases_its_project_and_preset() {
    let state = State::new();
    let store = state.admitted(PROJECT, PRESET, "running", false, true);
    assert_eq!(
        census(&state, store),
        [(conflict(), conflict()), (conflict(), conflict())]
    );
    let store = JobStore::open_owner(&state.jobs()).unwrap();
    let (ended, _) = workspace_job(PROJECT, PRESET, "succeeded", false, true);
    store.persist(&ended, "2026-09-14T00:00:01Z").unwrap();
    assert_eq!(census(&state, store), [(None, None), (None, None)]);
}

/// A record the census cannot verify against the request it was admitted
/// under refuses every mutation rather than being skipped: here a terminal
/// Job, which would otherwise refuse nothing, admitted under another
/// request's fingerprint.
#[test]
fn an_unverifiable_record_refuses_every_mutation() {
    let state = State::new();
    let (record, _) = workspace_job(PROJECT, PRESET, "succeeded", false, false);
    let (_, other) = workspace_job("project-elsewhere", PRESET, "succeeded", false, false);
    let store = state.admitted_as(&record, &other);
    let unreadable = Some("recordUnreadable".to_owned());
    assert_eq!(
        census(&state, store),
        [
            (unreadable.clone(), unreadable.clone()),
            (unreadable.clone(), unreadable)
        ]
    );
}
