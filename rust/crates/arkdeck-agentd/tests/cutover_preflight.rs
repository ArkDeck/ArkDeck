//! `arkdeck-agentd --cutover-preflight [--hold-instance-lock]`, the real
//! binary over temporary homes: design §G.4's cutover preflight decided by
//! the shared table (#2026) over a production state root seeded with
//! Swift-recorded Jobs, agent executions, a capability store and a tool index
//! with a pending selection.
//!
//! Every process runs with its environment cleared and `CFFIXED_USER_HOME`
//! naming a temporary home below `/private/tmp`; the account's state, its
//! LaunchAgent and launchd are never touched, and nothing here composes a
//! Runtime.
#![cfg(target_os = "macos")]

use arkdeck_platform::{HostDirectory, HostSqlite, SqliteValue};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::{Mutex, MutexGuard, PoisonError};

/// One test at a time. One takes Swift's instance lock in this process while
/// the others spawn the daemon, and a child shares every descriptor of this
/// process until its exec, so a lock let go of here could still read as
/// held.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Swift `RuntimeJobRepository.schemaStatements`, as the Job owner keeps them.
const SCHEMA: [&str; 4] = [
    "CREATE TABLE runtime_job(\n  job_id TEXT PRIMARY KEY,\n  idempotency_key TEXT NOT NULL UNIQUE,\n  request_hash TEXT NOT NULL,\n  state TEXT NOT NULL,\n  admission_sequence INTEGER NOT NULL,\n  created_at_utc TEXT NOT NULL,\n  created_at_order_key TEXT NOT NULL,\n  updated_at_utc TEXT NOT NULL,\n  version INTEGER NOT NULL CHECK(version >= 1),\n  initial_record_json BLOB\n)",
    "CREATE INDEX runtime_job_updated_idx ON runtime_job(updated_at_utc DESC, job_id)",
    "CREATE INDEX runtime_job_created_idx ON runtime_job(created_at_order_key, job_id COLLATE BINARY)",
    "CREATE UNIQUE INDEX runtime_job_admission_sequence_idx ON runtime_job(admission_sequence)",
];

/// Swift-recorded Jobs, `(fixture directory, Job)`, each named by the state
/// its record holds.
const SUCCEEDED: (&str, &str) = (
    "screen-sequence/store/jobs",
    "job-b4de03b9286b93c6aa5eae08f49e4d2a",
);
const PARKED: (&str, &str) = (
    "screen-sequence/store/jobs",
    "job-3ff50dc0d1e7c9f4bd80177e40f5b071",
);
const PREFLIGHT: (&str, &str) = (
    "job-submit-analyzer/store/jobs",
    "job-d65aafabb1a7a56843cc0faef4ef072e",
);
const RESUMING: (&str, &str) = (
    "readback-reconcile/store/jobs",
    "job-9b3bd3e59373446bcdeaad9bd0a97001",
);

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

fn directory(path: &Path) {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

/// Copies the regular files of `source` into `destination`, owner-only.
fn copy_files(source: &Path, destination: &Path) {
    directory(destination);
    for entry in fs::read_dir(source).unwrap() {
        let path = entry.unwrap().path();
        if path.is_file() {
            let target = destination.join(path.file_name().unwrap());
            fs::copy(&path, &target).unwrap();
            fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        }
    }
}

/// A temporary account home, physical and short.
struct Home(PathBuf);

impl Home {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/acp-{nonce:016x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }

    fn state(&self) -> PathBuf {
        self.0.join("Library/Application Support/ArkDeck/Agentd")
    }

    fn bootstrap(&self) -> PathBuf {
        self.0
            .join("Library/Application Support/ArkDeck/Bootstrap/v1")
    }

    fn job(&self, job: (&str, &str)) -> PathBuf {
        self.state().join("jobs").join(job.1)
    }

    /// The state a Swift daemon leaves: its instance lock, the Job index and
    /// the four recorded Jobs, three recorded agent executions (completed,
    /// abandoned, still orchestrating), a capability store whose uses are
    /// confirmed or parked on an unknown outcome, and a tool index with a
    /// pending selection.
    fn seed(&self) {
        let state = self.state();
        directory(&state);
        fs::write(state.join("instance.lock"), b"").unwrap();
        fs::set_permissions(
            state.join("instance.lock"),
            fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        directory(&state.join("jobs"));
        for job in [SUCCEEDED, PARKED, PREFLIGHT, RESUMING] {
            copy_files(&fixture(job.0).join(job.1), &self.job(job));
        }
        // Owner-only before SQLite opens it, so the write-ahead log and
        // shared-memory index Apple's SQLite keeps beside it take its mode,
        // as they do in a Swift state directory.
        let database = state.join("runtime-jobs.sqlite3");
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&database)
            .unwrap();
        let mut db = HostSqlite::open(&database, false, false).unwrap();
        for statement in SCHEMA {
            db.execute(statement, &[]).unwrap();
        }
        db.execute("PRAGMA user_version=1", &[]).unwrap();
        db.query("PRAGMA journal_mode=WAL", &[], 1024).unwrap();
        for (sequence, (job, state)) in [
            (SUCCEEDED.1, "succeeded"),
            (PARKED.1, "waitingForRecovery"),
            (PREFLIGHT.1, "preflight"),
            (RESUMING.1, "resumeAtConfirmedSafeBoundary"),
        ]
        .into_iter()
        .enumerate()
        {
            db.execute(
                "INSERT INTO runtime_job VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, NULL)",
                &[
                    SqliteValue::Text(job.into()),
                    SqliteValue::Text(format!("key-{job}")),
                    SqliteValue::Text("0".repeat(64)),
                    SqliteValue::Text(state.into()),
                    SqliteValue::Integer(sequence as i64 + 1),
                    SqliteValue::Text("2026-09-01T00:00:00Z".into()),
                    SqliteValue::Text(format!("{sequence:016x}")),
                    SqliteValue::Text("2026-09-01T00:00:00Z".into()),
                ],
            )
            .unwrap();
        }
        drop(db);
        copy_files(
            &fixture("agent-lifecycle/agent-executions"),
            &state.join("agent-executions"),
        );
        copy_files(
            &fixture("capture-diagnostics-file-legs/store/capabilities"),
            &state.join("capabilities"),
        );
        let bootstrap = self.bootstrap();
        directory(&bootstrap);
        fs::copy(
            fixture(
                "tool-selection-registry/indexes/4f50525bac82367ad0ceaa9a8b82ca8502eb16fb6aeae28c1f591cc291b3fd0f.json",
            ),
            bootstrap.join("tools.json"),
        )
        .unwrap();
        fs::set_permissions(
            bootstrap.join("tools.json"),
            fs::Permissions::from_mode(0o600),
        )
        .unwrap();
    }

    /// Sets one Job's index row, as a crash window can leave it apart from
    /// the Job's record and journal.
    fn index_state(&self, job: &str, state: &str) {
        let mut db =
            HostSqlite::open(&self.state().join("runtime-jobs.sqlite3"), false, false).unwrap();
        db.execute(
            "UPDATE runtime_job SET state = ? WHERE job_id = ?",
            &[
                SqliteValue::Text(state.into()),
                SqliteValue::Text(job.into()),
            ],
        )
        .unwrap();
    }

    /// Every entry below the home with its mode, inode and, for a file, its
    /// size, modification time and content. A directory's times and the Job
    /// index's shared-memory index are left out: that index is SQLite's
    /// coordination between connections, where a reader records its read
    /// mark (`arkdeck_hoststore::cutover_facts`).
    fn tree(&self) -> Vec<(String, u32, u64, i64, i64, Option<String>)> {
        let mut entries = Vec::new();
        let mut pending = vec![self.0.clone()];
        while let Some(directory) = pending.pop() {
            for entry in fs::read_dir(&directory).unwrap() {
                let path = entry.unwrap().path();
                let metadata = fs::symlink_metadata(&path).unwrap();
                if metadata.is_dir() {
                    pending.push(path.clone());
                }
                let file = metadata.is_file() && !path.ends_with("runtime-jobs.sqlite3-shm");
                entries.push((
                    path.strip_prefix(&self.0).unwrap().display().to_string(),
                    metadata.mode(),
                    if file { metadata.len() } else { 0 },
                    if file {
                        metadata.mtime() * 1_000_000_000 + metadata.mtime_nsec()
                    } else {
                        0
                    },
                    metadata.ino() as i64,
                    file.then(|| arkdeck_contract::sha256_hex(&fs::read(&path).unwrap())),
                ));
            }
        }
        entries.sort();
        entries
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn agentd() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_arkdeck-agentd"))
}

/// The preflight over `home` from `executable`, with nothing else from this
/// process's environment.
fn preflight_with(executable: &Path, home: &Home, arguments: &[&str]) -> Output {
    Command::new(executable)
        .args(arguments)
        .env_clear()
        .env("CFFIXED_USER_HOME", &home.0)
        .env("HOME", &home.0)
        .env("ARKDECK_RUNTIME_COMPOSITION", "production")
        .output()
        .unwrap()
}

fn preflight(home: &Home, hold: bool) -> Value {
    let arguments: &[&str] = if hold {
        &["--cutover-preflight", "--hold-instance-lock"]
    } else {
        &["--cutover-preflight"]
    };
    let output = preflight_with(&agentd(), home, arguments);
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let document: Value = serde_json::from_slice(&output.stdout).unwrap();
    // One canonical document.
    let mut canonical = arkdeck_contract::canonical_json(&document).unwrap();
    canonical.push(b'\n');
    assert_eq!(canonical, output.stdout);
    assert_eq!(document["schemaVersion"], "arkdeck.cutover-preflight/1");
    document
}

fn blocks(document: &Value) -> Vec<Value> {
    document["blocks"].as_array().unwrap().clone()
}

/// The table's blocking states, read from the copy the Rust contract compiles.
fn blocking_states() -> Vec<String> {
    let table: Value =
        serde_json::from_slice(&fs::read(fixture("job-state-preflight/table.json")).unwrap())
            .unwrap();
    table["states"]
        .as_object()
        .unwrap()
        .iter()
        .filter(|(_, class)| *class == "blocking")
        .map(|(state, _)| state.clone())
        .collect()
}

#[test]
fn a_swift_state_root_is_refused_by_every_fact_that_blocks_and_carries_the_rest() {
    let _turn = turn();
    let home = Home::new();
    home.seed();
    let before = home.tree();
    let document = preflight(&home, false);
    assert_eq!(document["stateDirectory"], home.state().to_str().unwrap());
    assert_eq!(document["instanceLockHeld"], false);
    assert_eq!(document["clear"], false);
    assert_eq!(document["snapshot"], Value::Null);
    let blocks = blocks(&document);
    // The admitted Job and the one resuming at its confirmed boundary are in
    // flight; the latter's journal also holds its outstanding intent.
    assert!(
        blocks.contains(&json!({"kind": "jobState", "jobId": PREFLIGHT.1, "state": "preflight"})),
        "{blocks:?}"
    );
    assert!(
        blocks.contains(&json!({"kind": "jobState", "jobId": RESUMING.1,
            "state": "resumeAtConfirmedSafeBoundary"})),
        "{blocks:?}"
    );
    // The execution still orchestrating blocks; the completed and abandoned
    // ones do not.
    let executions: Vec<&Value> = blocks
        .iter()
        .filter(|block| block["kind"] == "activeAgentExecution")
        .collect();
    assert_eq!(executions.len(), 1, "{blocks:?}");
    assert_eq!(executions[0]["state"], "orchestrating");
    assert!(
        blocks.contains(&json!({"kind": "pendingToolSelection", "controlActionId": "select-b"})),
        "{blocks:?}"
    );
    // Nothing else is read as unreadable or as another Job's refusal.
    for block in &blocks {
        assert!(
            [
                "jobState",
                "unresolvedJournal",
                "activeAgentExecution",
                "pendingToolSelection"
            ]
            .contains(&block["kind"].as_str().unwrap()),
            "{block}"
        );
        if block["kind"] == "jobState" || block["kind"] == "unresolvedJournal" {
            assert!(
                [PREFLIGHT.1, RESUMING.1].contains(&block["jobId"].as_str().unwrap()),
                "{block}"
            );
        }
    }
    // The parked outcome-unknown lane and the terminal Job are carried over
    // as they are, as are the confirmed and outcome-unknown uses.
    assert_eq!(
        document["carriedOver"],
        json!({"parkedJobIds": [PARKED.1], "terminalJobCount": 1, "outcomeUnknownUseCount": 3})
    );
    assert_eq!(
        document["counts"],
        json!({"jobs": 4, "agentExecutions": 3, "capabilityUses": 11})
    );
    // Read only: not one entry below the home changed.
    assert_eq!(home.tree(), before);
}

#[test]
fn each_of_the_tables_thirteen_blocking_states_refuses_whichever_source_gives_it() {
    let _turn = turn();
    let home = Home::new();
    home.seed();
    let states = blocking_states();
    assert_eq!(states.len(), 13, "{states:?}");
    // A terminal Job whose index row reads each blocking state, as a crash
    // window can leave the row ahead of its record and journal: the most
    // conservative class wins.
    for state in states.iter().map(String::as_str).chain(["futureState"]) {
        home.index_state(SUCCEEDED.1, state);
        let document = preflight(&home, false);
        assert!(
            blocks(&document)
                .contains(&json!({"kind": "jobState", "jobId": SUCCEEDED.1, "state": state})),
            "{state}: {document}"
        );
        assert_eq!(document["carriedOver"]["terminalJobCount"], 0, "{state}");
    }
    // Parked and terminal sources carry over: the parked lane stays parked
    // whatever its row says, and never blocks.
    home.index_state(SUCCEEDED.1, "succeeded");
    home.index_state(PARKED.1, "succeeded");
    let document = preflight(&home, false);
    assert_eq!(document["carriedOver"]["parkedJobIds"], json!([PARKED.1]));
    assert!(
        !blocks(&document)
            .iter()
            .any(|block| block["jobId"] == PARKED.1 || block["jobId"] == SUCCEEDED.1),
        "{document}"
    );
}

#[test]
fn an_unresolved_journal_refuses_unless_the_job_is_parked() {
    let _turn = turn();
    let home = Home::new();
    home.seed();
    // A terminal Job whose journal ends in a torn record.
    let journal = home.job(SUCCEEDED).join("journal.jsonl");
    let mut bytes = fs::read(&journal).unwrap();
    bytes.extend_from_slice(b"{\"eventId\":\"torn");
    fs::write(&journal, &bytes).unwrap();
    let document = preflight(&home, false);
    assert!(
        blocks(&document).contains(&json!({"kind": "unresolvedJournal", "jobId": SUCCEEDED.1})),
        "{document}"
    );
    // The same tail on the parked lane is carried over with it.
    let journal = home.job(PARKED).join("journal.jsonl");
    let mut bytes = fs::read(&journal).unwrap();
    bytes.extend_from_slice(b"{\"eventId\":\"torn");
    fs::write(&journal, &bytes).unwrap();
    let document = preflight(&home, false);
    assert!(
        !blocks(&document)
            .iter()
            .any(|block| block["jobId"] == PARKED.1),
        "{document}"
    );
    // A record that does not decode blocks the Job it names, by that name.
    fs::write(home.job(SUCCEEDED).join("job-record.json"), b"{}").unwrap();
    let document = preflight(&home, false);
    assert!(
        blocks(&document).contains(&json!({"kind": "jobState", "jobId": SUCCEEDED.1,
            "state": "unreadableRecord"})),
        "{document}"
    );
    // So does a journal that does not replay, even on a terminal Job.
    let home = Home::new();
    home.seed();
    fs::write(
        home.job(SUCCEEDED).join("journal.jsonl"),
        b"not a journal\n",
    )
    .unwrap();
    let document = preflight(&home, false);
    assert!(
        blocks(&document).contains(&json!({"kind": "unresolvedJournal", "jobId": SUCCEEDED.1})),
        "{document}"
    );
}

#[test]
fn a_job_is_read_from_whichever_source_names_it() {
    let _turn = turn();
    let home = Home::new();
    home.seed();
    // A crash window can leave a Job in `jobs/` with no index row yet ...
    let mut db =
        HostSqlite::open(&home.state().join("runtime-jobs.sqlite3"), false, false).unwrap();
    db.execute(
        "DELETE FROM runtime_job WHERE job_id = ?",
        &[SqliteValue::Text(PREFLIGHT.1.into())],
    )
    .unwrap();
    drop(db);
    // ... or an index row whose Job directory is gone.
    fs::remove_dir_all(home.job(RESUMING)).unwrap();
    let document = preflight(&home, false);
    let refused = blocks(&document);
    assert!(
        refused.contains(&json!({"kind": "jobState", "jobId": PREFLIGHT.1, "state": "preflight"})),
        "{refused:?}"
    );
    assert!(
        refused.contains(&json!({"kind": "jobState", "jobId": RESUMING.1,
            "state": "resumeAtConfirmedSafeBoundary"})),
        "{refused:?}"
    );
    assert_eq!(document["counts"]["jobs"], 4);
    // A file, or a name that is no Job identity, is not read as a Job ...
    fs::write(home.state().join("jobs/job-notes"), b"").unwrap();
    directory(&home.state().join("jobs/.staging"));
    let document = preflight(&home, false);
    assert_eq!(document["counts"]["jobs"], 4, "{document}");
    // ... but a Job directory no source gives a state for blocks: an
    // admission a crash cut short cannot be proved settled.
    let empty = "job-00000000000000000000000000000000";
    directory(&home.state().join("jobs").join(empty));
    let document = preflight(&home, false);
    assert!(
        blocks(&document).contains(&json!({"kind": "jobState", "jobId": empty,
            "state": "missingRecord"})),
        "{document}"
    );
}

#[test]
fn an_unsettled_use_and_an_unreadable_source_refuse() {
    let _turn = turn();
    let home = Home::new();
    home.seed();
    // A capability store whose last use is only reserved.
    fs::remove_dir_all(home.state().join("capabilities")).unwrap();
    copy_files(
        &fixture("capability-resolve/store/capabilities"),
        &home.state().join("capabilities"),
    );
    // Its four uses: confirmed twice (once after an unknown outcome), one
    // safe to reflash after an unknown outcome, and the last consumed with no
    // outcome yet.
    let document = preflight(&home, false);
    let unsettled: Vec<Value> = blocks(&document)
        .into_iter()
        .filter(|block| block["kind"] == "unsettledCapabilityUse")
        .collect();
    assert_eq!(
        unsettled,
        [
            json!({"kind": "unsettledCapabilityUse", "capabilityId": "CAP-RT-RESOLVE-SAFE",
            "useOrdinal": 2, "jobId": "job-s2"})
        ]
    );
    assert_eq!(document["counts"]["capabilityUses"], 4);
    assert_eq!(document["carriedOver"]["outcomeUnknownUseCount"], 0);
    // A ledger line that does not decode leaves the uses unknown.
    let ledger = home
        .state()
        .join("capabilities/runtime-capabilities.ledger");
    let mut bytes = fs::read(&ledger).unwrap();
    bytes.extend_from_slice(b"{\"kind\":\"consumed\"}\n");
    fs::write(&ledger, &bytes).unwrap();
    let document = preflight(&home, false);
    assert!(
        blocks(&document)
            .iter()
            .any(|block| block["kind"] == "unreadable" && block["source"] == "capabilities"),
        "{document}"
    );
    // A Job index that is not the Swift layout cannot be read, and says so.
    fs::write(home.state().join("runtime-jobs.sqlite3"), b"not a database").unwrap();
    let document = preflight(&home, false);
    assert!(
        blocks(&document)
            .iter()
            .any(|block| block["kind"] == "unreadable" && block["source"] == "jobIndex"),
        "{document}"
    );
    assert_eq!(document["clear"], false);
}

#[test]
fn a_state_with_nothing_in_flight_is_clear_and_the_held_pass_records_its_snapshot() {
    let _turn = turn();
    let home = Home::new();
    home.seed();
    // Only the terminal and parked Jobs, the settled executions and uses, and
    // no pending selection.
    for job in [PREFLIGHT, RESUMING] {
        fs::remove_dir_all(home.job(job)).unwrap();
        let mut db =
            HostSqlite::open(&home.state().join("runtime-jobs.sqlite3"), false, false).unwrap();
        db.execute(
            "DELETE FROM runtime_job WHERE job_id = ?",
            &[SqliteValue::Text(job.1.into())],
        )
        .unwrap();
    }
    for entry in fs::read_dir(home.state().join("agent-executions")).unwrap() {
        let path = entry.unwrap().path();
        let record: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        if record["state"] == "orchestrating" {
            fs::remove_file(&path).unwrap();
        }
    }
    // A recorded index whose selection is active, with nothing pending.
    fs::copy(
        fixture(
            "tool-selection-registry/indexes/5aa44e6b21e766bef6c1e1626fb34b404c25d470fe189055d324111a40209dfc.json",
        ),
        home.bootstrap().join("tools.json"),
    )
    .unwrap();
    fs::set_permissions(
        home.bootstrap().join("tools.json"),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let before = home.tree();
    let document = preflight(&home, false);
    assert_eq!(document["clear"], true, "{document}");
    assert_eq!(document["blocks"], json!([]));

    // The held pass: the lock taken, then every file below the state
    // directory measured before the facts are read.
    let held = preflight(&home, true);
    assert_eq!(held["instanceLockHeld"], true);
    assert_eq!(held["clear"], true, "{held}");
    let snapshot = &held["snapshot"];
    assert_eq!(snapshot["schemaVersion"], "arkdeck.cutover-snapshot/1");
    assert_eq!(snapshot["stateDirectoryPresent"], true);
    let entries = snapshot["entries"].as_array().unwrap();
    let journal = format!("jobs/{}/journal.jsonl", SUCCEEDED.1);
    let recorded = entries
        .iter()
        .find(|entry| entry["path"] == journal.as_str())
        .unwrap();
    let bytes = fs::read(home.job(SUCCEEDED).join("journal.jsonl")).unwrap();
    assert_eq!(
        *recorded,
        json!({"path": journal, "kind": "file", "byteCount": bytes.len(),
            "sha256": arkdeck_contract::sha256_hex(&bytes)})
    );
    let files = entries
        .iter()
        .filter(|entry| entry["kind"] == "file")
        .count();
    assert_eq!(snapshot["fileCount"], files);
    let mut canonical = entries.clone();
    canonical.sort_by(|a, b| a["path"].as_str().cmp(&b["path"].as_str()));
    assert_eq!(&canonical, entries);
    assert_eq!(
        snapshot["rootSha256"],
        arkdeck_contract::sha256_hex(
            &arkdeck_contract::canonical_json(&Value::Array(entries.clone())).unwrap()
        )
    );
    // The same state measures the same (but for the index's shared memory,
    // SQLite's own), and no pass changed the state.
    let again = preflight(&home, true);
    let state_entries = |snapshot: &Value| -> Vec<Value> {
        snapshot["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| entry["path"] != "runtime-jobs.sqlite3-shm")
            .cloned()
            .collect()
    };
    assert_eq!(state_entries(&again["snapshot"]), state_entries(snapshot));
    assert!(
        entries
            .iter()
            .any(|entry| entry["path"] == "runtime-jobs.sqlite3" && entry["kind"] == "file")
    );
    assert_eq!(home.tree(), before);
}

#[test]
fn the_held_pass_refuses_while_another_runtime_holds_the_instance_lock() {
    let _turn = turn();
    let home = Home::new();
    home.seed();
    // This test process holds the lock, as a running Swift daemon does.
    let state = HostDirectory::open(&home.state()).unwrap();
    let lock = state.lock_document("instance.lock").unwrap();
    let held = preflight(&home, true);
    assert_eq!(held["instanceLockHeld"], false);
    assert_eq!(held["snapshot"], Value::Null);
    assert!(
        blocks(&held).contains(&json!({"kind": "runtimeRunning",
            "reason": "another Runtime holds the instance lock of the state directory"})),
        "{held}"
    );
    // The first pass reads beside the running Runtime, taking no lock.
    let free = preflight(&home, false);
    assert!(
        !blocks(&free)
            .iter()
            .any(|block| block["kind"] == "runtimeRunning")
    );
    drop(lock);
    // No state at all: nothing to carry over, an empty snapshot.
    let empty = Home::new();
    let document = preflight(&empty, true);
    assert_eq!(document["clear"], true, "{document}");
    assert_eq!(document["snapshot"]["stateDirectoryPresent"], false);
    assert_eq!(document["snapshot"]["entries"], json!([]));
    assert!(!empty.state().exists());
}

#[test]
fn the_preflight_runs_only_as_the_production_layouts_one_shot_read() {
    let _turn = turn();
    let home = Home::new();
    home.seed();
    let before = home.tree();
    // Never under the facade's executable name.
    let facade = home.0.join("arkdeck-facade");
    fs::copy(agentd(), &facade).unwrap();
    let output = preflight_with(&facade, &home, &["--cutover-preflight"]);
    assert_eq!(output.status.code(), Some(69));
    assert!(output.stdout.is_empty());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("facade"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    fs::remove_file(&facade).unwrap();
    // Only the production layout, and only its two forms.
    let output = Command::new(agentd())
        .arg("--cutover-preflight")
        .env_clear()
        .env("CFFIXED_USER_HOME", &home.0)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(64));
    for arguments in [
        &["--cutover-preflight", "--hold"][..],
        &["--cutover-preflight", "--hold-instance-lock", "x"][..],
    ] {
        let output = preflight_with(&agentd(), &home, arguments);
        assert_eq!(output.status.code(), Some(64), "{arguments:?}");
        assert!(output.stdout.is_empty());
    }
    // Another composition's input is refused before anything is read.
    let output = Command::new(agentd())
        .arg("--cutover-preflight")
        .env_clear()
        .env("CFFIXED_USER_HOME", &home.0)
        .env("ARKDECK_RUNTIME_COMPOSITION", "production")
        .env("ARKDECK_DEVELOPMENT_STATE_ROOT", home.0.join("dev"))
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69));
    assert_eq!(home.tree(), before);
}

#[test]
fn the_job_index_is_read_the_way_swift_inspects_it() {
    let _turn = turn();
    let home = Home::new();
    home.seed();
    let state = home.state();
    let database = state.join("runtime-jobs.sqlite3");
    let log = state.join("runtime-jobs.sqlite3-wal");
    let index = state.join("runtime-jobs.sqlite3-shm");
    let bytes = fs::read(&database).unwrap();
    // Beside a shared-memory index (a Swift daemon's, live or stopped), a
    // read-only connection reads through it: the database and its log are
    // left as they are.
    let logged = fs::read(&log).ok();
    let document = preflight(&home, false);
    assert_eq!(document["counts"]["jobs"], 4);
    assert_eq!(fs::read(&database).unwrap(), bytes);
    assert_eq!(fs::read(&log).ok(), logged);
    // Without one there is no log to replay: a connection that never writes
    // reads the database, which it leaves as it is; the log and index it may
    // leave beside it take the database's own mode.
    for name in [&log, &index] {
        let _ = fs::remove_file(name);
    }
    let document = preflight(&home, false);
    assert!(
        !blocks(&document)
            .iter()
            .any(|block| block["kind"] == "unreadable"),
        "{document}"
    );
    assert_eq!(document["counts"]["jobs"], 4);
    assert_eq!(fs::read(&database).unwrap(), bytes);
    for name in [&log, &index] {
        if let Ok(metadata) = fs::symlink_metadata(name) {
            assert_eq!(metadata.mode() & 0o777, 0o600, "{}", name.display());
        }
    }
    if let Ok(logged) = fs::read(&log) {
        assert!(logged.is_empty());
    }
    // A log with content but no index would be replayed by that connection,
    // so the index is refused unread.
    let _ = fs::remove_file(&index);
    fs::write(&log, b"a log with frames").unwrap();
    fs::set_permissions(&log, fs::Permissions::from_mode(0o600)).unwrap();
    let document = preflight(&home, false);
    assert!(
        blocks(&document)
            .iter()
            .any(|block| block["kind"] == "unreadable" && block["source"] == "jobIndex"),
        "{document}"
    );
    assert_eq!(fs::read(&database).unwrap(), bytes);
    assert_eq!(fs::read(&log).unwrap(), b"a log with frames");
    assert!(!index.exists());
}
