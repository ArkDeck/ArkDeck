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

/// A DAYU200 Flash Job the engine drove itself, recorded by the Rockchip
/// start-up oracle.
const LOADER: (&str, &str) = (
    "rockchip-startup/inputs/alias.complete/Agentd/jobs",
    "job-11111111111111111111111111111111",
);
const LOADER_INTENT: &str = "intent-enter-loader-mode";

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

    /// Only the terminal and parked Jobs, the settled executions and uses,
    /// and no pending selection: nothing the table refuses.
    fn quiet(&self) {
        for job in [PREFLIGHT, RESUMING] {
            fs::remove_dir_all(self.job(job)).unwrap();
            let mut db =
                HostSqlite::open(&self.state().join("runtime-jobs.sqlite3"), false, false).unwrap();
            db.execute(
                "DELETE FROM runtime_job WHERE job_id = ?",
                &[SqliteValue::Text(job.1.into())],
            )
            .unwrap();
        }
        for entry in fs::read_dir(self.state().join("agent-executions")).unwrap() {
            let path = entry.unwrap().path();
            let record: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
            if record["state"] == "orchestrating" {
                fs::remove_file(&path).unwrap();
            }
        }
        self.active_tool_selection();
    }

    /// A recorded tool index whose selection is active, with nothing pending.
    fn active_tool_selection(&self) {
        directory(&self.bootstrap());
        fs::copy(
            fixture(
                "tool-selection-registry/indexes/5aa44e6b21e766bef6c1e1626fb34b404c25d470fe189055d324111a40209dfc.json",
            ),
            self.bootstrap().join("tools.json"),
        )
        .unwrap();
        fs::set_permissions(
            self.bootstrap().join("tools.json"),
            fs::Permissions::from_mode(0o600),
        )
        .unwrap();
    }

    /// The Flash Job of the Rockchip start-up oracle, which the engine drove
    /// itself as it did before CHG-059, parked as Swift's engine parks it at
    /// its own enter-Loader transition: its journal ends at the
    /// `enter-loader-mode` intent, outstanding at binding revision 2 of its
    /// Target, and then waits for recovery; its record keeps that intent with
    /// its outcome unknown. `operation` is how its request names the Flash.
    fn park_at_loader(&self, operation: Value) {
        let directory = self.job(LOADER);
        copy_files(&fixture(LOADER.0).join(LOADER.1), &directory);
        let reference = match operation["version"].as_i64() {
            Some(version) => format!("{}@{version}", operation["id"].as_str().unwrap()),
            None => operation["id"].as_str().unwrap().to_owned(),
        };
        self.edit_record(LOADER, |record| {
            record["state"] = json!("waitingForRecovery");
            record["outcomeUnknown"] = json!(true);
            record["recoveryStepID"] = json!("enter-loader-mode");
            record["recoveryIntentEventID"] = json!(LOADER_INTENT);
            record["operationReference"] = json!(reference);
            record["request"]["operation"] = operation.clone();
            record["originalSubmissionRequest"]["operation"] = operation;
        });
        self.edit_journal(LOADER, |events| {
            let intent = events
                .iter()
                .position(|event| event["eventId"] == LOADER_INTENT)
                .unwrap();
            events.truncate(intent + 1);
            let mut parked = events[intent - 1].clone();
            assert_eq!(parked["kind"], "stateTransition");
            parked["eventId"] = json!(format!("parked-{}", LOADER.1));
            parked["payload"] = json!({"from": "running", "to": "waitingForRecovery",
                "reason": "outcomeUnknown: the board did not answer after entering the Loader",
                "triggerEventId": null});
            events.push(parked);
        });
    }

    /// Rewrites one Job's record as `edit` leaves it.
    fn edit_record(&self, job: (&str, &str), edit: impl FnOnce(&mut Value)) {
        let path = self.job(job).join("job-record.json");
        let mut record: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        edit(&mut record);
        fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
    }

    /// Rewrites one Job's journal as `edit` leaves its events, numbered again
    /// in their order.
    fn edit_journal(&self, job: (&str, &str), edit: impl FnOnce(&mut Vec<Value>)) {
        let path = self.job(job).join("journal.jsonl");
        let mut events: Vec<Value> = fs::read_to_string(&path)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        edit(&mut events);
        let mut bytes = Vec::new();
        for (sequence, event) in events.iter_mut().enumerate() {
            event["sequence"] = json!(sequence);
            bytes.extend(serde_json::to_vec(event).unwrap());
            bytes.push(b'\n');
        }
        fs::write(&path, bytes).unwrap();
    }

    fn sessions(&self) -> PathBuf {
        self.0.join("Library/Application Support/ArkDeck/Sessions")
    }

    /// A state holding no Job: the instance lock, a capability store whose
    /// checkpoint lets a device mutation's proof pass over Job history, and a
    /// tool index with nothing pending.
    fn minimal(&self) {
        let state = self.state();
        directory(&state);
        fs::write(state.join("instance.lock"), b"").unwrap();
        fs::set_permissions(
            state.join("instance.lock"),
            fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        copy_files(
            &fixture("capture-diagnostics-file-legs/store/capabilities"),
            &state.join("capabilities"),
        );
        self.active_tool_selection();
    }

    /// What a publication of `job`'s Session that stopped before its
    /// Journal leaves at `location` below `root`: the Session's directories
    /// and its identity, and no Manifest.
    fn stopped_publication(&self, root: &Path, location: &str, job: &str) -> PathBuf {
        let session = root.join(location);
        for part in [
            "audit",
            "artifacts/derived",
            "artifacts/partial",
            "artifacts/raw",
        ] {
            directory(&session.join(part));
        }
        let identity = session.join(".session-identity.json");
        fs::write(
            &identity,
            format!(r#"{{"jobId":"{job}","schemaVersion":"1.0.0","sessionId":"session-{job}"}}"#),
        )
        .unwrap();
        fs::set_permissions(&identity, fs::Permissions::from_mode(0o600)).unwrap();
        session
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
    home.quiet();
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

/// The Loader transition block the preflight names for the parked Flash Job.
fn loader_block() -> Value {
    json!({"kind": "loaderTransitionAwaitingBinding", "jobId": LOADER.1,
        "targetId": "TGT-8b3d0a34cf32", "expectedBindingRevision": 2})
}

/// A copy of the parked Flash Job's enter-Loader intent as another step of
/// `effect`, which the journal holds before it.
fn another_intent(events: &mut Vec<Value>, step: &str, effect: &str) -> usize {
    let at = events
        .iter()
        .position(|event| event["eventId"] == LOADER_INTENT)
        .unwrap();
    let mut intent = events[at].clone();
    intent["eventId"] = json!(format!("intent-{step}"));
    intent["stepId"] = json!(step);
    intent["payload"]["step"]["id"] = json!(step);
    intent["payload"]["step"]["effect"] = json!(effect);
    events.insert(at, intent);
    at
}

/// The outcome of the intent at `at`, as the engine records it.
fn outcome(events: &[Value], at: usize, certainty: &str) -> Value {
    let intent = &events[at];
    let result = if certainty == "confirmed" {
        "succeeded"
    } else {
        "failed"
    };
    json!({"attempt": intent["attempt"],
        "eventId": format!("outcome-{}", intent["stepId"].as_str().unwrap()),
        "jobId": intent["jobId"], "kind": "stepOutcome",
        "payload": {"correlatesToIntentEventId": intent["eventId"], "outcomeCertainty": certainty,
            "result": result, "summary": "recorded for the preflight"},
        "schemaVersion": "1.0.0", "sequence": 0, "sessionId": intent["sessionId"],
        "stepId": intent["stepId"], "timestamp": intent["timestamp"]})
}

#[test]
fn a_parked_flash_only_swift_can_settle_at_its_loader_transition_refuses_the_cutover() {
    let _turn = turn();
    // Each spelling of the DAYU200 Flash a request names.
    for operation in [
        json!({"id": "flash.full-restore", "version": 1}),
        json!({"id": "flash.dayu200"}),
        json!({"id": "flash.dayu200", "version": 1}),
    ] {
        let home = Home::new();
        home.seed();
        home.quiet();
        home.park_at_loader(operation.clone());
        // The journal Swift's engine leaves: one intent outstanding, the
        // Loader transition, at binding revision 2.
        let journal = arkdeck_hoststore::inspect_journal(&home.job(LOADER)).unwrap();
        assert_eq!(journal.current_state.as_deref(), Some("waitingForRecovery"));
        assert_eq!(
            journal
                .outstanding_intents
                .iter()
                .map(|intent| (
                    intent.event_id.as_str(),
                    intent.effect.as_str(),
                    intent.binding_revision
                ))
                .collect::<Vec<_>>(),
            [(LOADER_INTENT, "deviceMutation", Some(2))]
        );
        assert!(journal.unknown_outcomes.is_empty());
        let before = home.tree();
        // Refused by name, with the Target and binding revision whose fresh
        // Loader binding settles it on Swift's Runtime, by both passes; every
        // other parked Job is carried over as before.
        let free = preflight(&home, false);
        let held = preflight(&home, true);
        for document in [&free, &held] {
            assert_eq!(document["clear"], false, "{operation}: {document}");
            assert_eq!(
                blocks(document),
                [loader_block()],
                "{operation}: {document}"
            );
            assert_eq!(
                document["carriedOver"]["parkedJobIds"],
                json!([LOADER.1, PARKED.1]),
                "{operation}"
            );
        }
        assert_eq!(held["instanceLockHeld"], true);
        assert_eq!(home.tree(), before, "{operation}");
    }
}

#[test]
fn a_parked_flash_swift_would_not_settle_is_carried_over_as_every_parked_job_is() {
    let _turn = turn();
    type Change = fn(&Home);
    let cases: [(&str, Change); 10] = [
        ("its ArkForge lane holds the transition", |home| {
            let sidecar = home.job(LOADER).join("arkforge-runtime-state.json");
            fs::write(&sidecar, b"{}").unwrap();
            fs::set_permissions(&sidecar, fs::Permissions::from_mode(0o600)).unwrap();
        }),
        (
            "another intent is outstanding, reading the device",
            |home| {
                home.edit_journal(LOADER, |events| {
                    another_intent(events, "probe-before-loader", "readOnly");
                });
            },
        ),
        ("another device mutation is outstanding", |home| {
            home.edit_journal(LOADER, |events| {
                another_intent(events, "reboot-before-loader", "deviceMutation");
            });
        }),
        ("the transition's outcome is recorded as unknown", |home| {
            home.edit_journal(LOADER, |events| {
                let at = events
                    .iter()
                    .position(|event| event["eventId"] == LOADER_INTENT)
                    .unwrap();
                let unknown = outcome(events, at, "outcomeUnknown");
                events.insert(at + 1, unknown);
            });
        }),
        ("a destructive step ran before it", |home| {
            home.edit_journal(LOADER, |events| {
                let at = another_intent(events, "flash-before-loader", "destructive");
                let confirmed = outcome(events, at, "confirmed");
                events.insert(at + 1, confirmed);
            });
        }),
        ("its journal ends in a torn record", |home| {
            let journal = home.job(LOADER).join("journal.jsonl");
            let mut bytes = fs::read(&journal).unwrap();
            bytes.extend_from_slice(b"{\"eventId\":\"torn");
            fs::write(&journal, &bytes).unwrap();
        }),
        ("its record does not keep the outcome unknown", |home| {
            home.edit_record(LOADER, |record| record["outcomeUnknown"] = json!(false));
        }),
        ("its request expects another binding revision", |home| {
            home.edit_record(LOADER, |record| {
                for request in ["request", "originalSubmissionRequest"] {
                    record[request]["target"]["expectedBindingRevision"] = json!(3);
                }
            });
        }),
        ("it is not a Flash", |home| {
            home.edit_record(LOADER, |record| {
                record["operationReference"] = json!("capture.screen-sequence@1");
                for request in ["request", "originalSubmissionRequest"] {
                    record[request]["operation"] =
                        json!({"id": "capture.screen-sequence", "version": 1});
                }
            });
        }),
        ("its record parks it at another step", |home| {
            home.edit_record(LOADER, |record| {
                record["recoveryStepID"] = json!("flash-partitions");
            });
        }),
    ];
    for (case, change) in cases {
        let home = Home::new();
        home.seed();
        home.quiet();
        home.park_at_loader(json!({"id": "flash.full-restore", "version": 1}));
        change(&home);
        // Still a record and a journal the Runtime reads, parked: carried
        // over for what they hold, not for being unreadable.
        let journal = arkdeck_hoststore::inspect_journal(&home.job(LOADER)).unwrap();
        assert_eq!(
            journal.current_state.as_deref(),
            Some("waitingForRecovery"),
            "{case}"
        );
        arkdeck_hoststore::JobRecord::decode(
            &fs::read(home.job(LOADER).join("job-record.json")).unwrap(),
        )
        .unwrap();
        let document = preflight(&home, false);
        assert_eq!(document["clear"], true, "{case}: {document}");
        assert_eq!(
            document["carriedOver"]["parkedJobIds"],
            json!([LOADER.1, PARKED.1]),
            "{case}"
        );
    }
    // Not parked, it is refused by the table's rules, never as a Loader
    // transition.
    let home = Home::new();
    home.seed();
    home.quiet();
    home.park_at_loader(json!({"id": "flash.full-restore", "version": 1}));
    let mut db =
        HostSqlite::open(&home.state().join("runtime-jobs.sqlite3"), false, false).unwrap();
    db.execute(
        "INSERT INTO runtime_job VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, NULL)",
        &[
            SqliteValue::Text(LOADER.1.into()),
            SqliteValue::Text(format!("key-{}", LOADER.1)),
            SqliteValue::Text("0".repeat(64)),
            SqliteValue::Text("running".into()),
            SqliteValue::Integer(9),
            SqliteValue::Text("2026-09-01T00:00:00Z".into()),
            SqliteValue::Text(format!("{:016x}", 9)),
            SqliteValue::Text("2026-09-01T00:00:00Z".into()),
        ],
    )
    .unwrap();
    drop(db);
    let document = preflight(&home, false);
    assert_eq!(
        blocks(&document),
        [
            json!({"kind": "jobState", "jobId": LOADER.1, "state": "running"}),
            json!({"kind": "unresolvedJournal", "jobId": LOADER.1}),
        ],
        "{document}"
    );
}

/// The Swift-recorded Job whose Session publication failed, as its durable
/// record keeps it: terminal, created 2026-07-29.
const FAILED_PUBLICATION: &str = "job-a9fda911411280791d18df748a6d3d84";

#[test]
fn a_retained_session_the_continuity_proof_refuses_refuses_the_cutover_in_its_own_words() {
    let _turn = turn();
    let home = Home::new();
    home.minimal();
    let state = home.state();
    let sessions = home.sessions();
    directory(&sessions);
    // The Job store's owner, opened before the state is measured: it answers
    // what a device mutation's proof refuses once this state is carried over.
    let jobs = arkdeck_hoststore::JobStore::open_state_root_owner(&state).unwrap();
    // What a publication that stopped before its Journal leaves, for a Job no
    // record of this state accounts for.
    let stray = "job-0000000000000000000000000000c001";
    let location = format!("2026/09/session-{stray}");
    let session = home.stopped_publication(&sessions, &location, stray);
    // What a device mutation's proof answers there. Asked first: the owner's
    // first read leaves the index's log and shared memory beside it, as a
    // Swift daemon's do, before the state is measured.
    let refusal = jobs.require_mutation_state(&state, &[]).unwrap_err();
    let before = home.tree();
    let free = preflight(&home, false);
    let held = preflight(&home, true);
    assert_eq!(home.tree(), before);
    assert!(
        refusal
            .message
            .contains(&format!("retained Session {location} has no Manifest")),
        "{refusal:?}"
    );
    let refused = json!({"kind": "retainedSessions", "sessionsRoot": sessions.to_str().unwrap(),
        "code": refusal.code, "message": refusal.message});
    for document in [&free, &held] {
        assert_eq!(document["clear"], false, "{document}");
        assert_eq!(
            blocks(document),
            std::slice::from_ref(&refused),
            "{document}"
        );
    }

    // A copy that holds its Journal, which replays clean, passes, as the
    // proof passes it (and Swift, which does not look below it).
    let journal = session.join("journal.jsonl");
    fs::copy(
        fixture(SUCCEEDED.0).join(SUCCEEDED.1).join("journal.jsonl"),
        &journal,
    )
    .unwrap();
    fs::set_permissions(&journal, fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(jobs.require_mutation_state(&state, &[]), Ok(()));
    let document = preflight(&home, false);
    assert_eq!(document["clear"], true, "{document}");
    fs::remove_dir_all(sessions.join("2026")).unwrap();

    // The Session a failed publication of a Job this state holds left is
    // accounted for by that Job's durable record, and passes.
    let record = fs::read(fixture("job-publication-current/failed/job-record.json")).unwrap();
    let decoded = arkdeck_hoststore::JobRecord::decode(&record).unwrap();
    assert_eq!(
        jobs.admit(&decoded, &"0".repeat(64)).unwrap(),
        arkdeck_hoststore::AdmissionVerdict::Admitted
    );
    let job = state.join("jobs").join(FAILED_PUBLICATION);
    directory(&job);
    fs::write(job.join("job-record.json"), &record).unwrap();
    // A terminal Journal of its own: the succeeded capture's, its events
    // named for this Job and its Session (their arguments, which their
    // digests cover, are left as they are).
    fs::copy(
        fixture(SUCCEEDED.0).join(SUCCEEDED.1).join("journal.jsonl"),
        job.join("journal.jsonl"),
    )
    .unwrap();
    for name in ["job-record.json", "journal.jsonl"] {
        fs::set_permissions(job.join(name), fs::Permissions::from_mode(0o600)).unwrap();
    }
    home.edit_journal(("", FAILED_PUBLICATION), |events| {
        for event in events {
            event["jobId"] = json!(FAILED_PUBLICATION);
            event["sessionId"] = json!(format!("session-{FAILED_PUBLICATION}"));
        }
    });
    let journal = arkdeck_hoststore::inspect_journal(&job).unwrap();
    assert_eq!(journal.current_state.as_deref(), Some("succeeded"));
    assert!(!journal.requires_recovery);
    let location = format!("2026/07/session-{FAILED_PUBLICATION}");
    home.stopped_publication(&sessions, &location, FAILED_PUBLICATION);
    assert!(jobs.failed_publication_accounts_for(
        &sessions,
        ["2026", "07", &format!("session-{FAILED_PUBLICATION}")]
    ));
    assert_eq!(jobs.require_mutation_state(&state, &[]), Ok(()));
    let before = home.tree();
    for hold in [false, true] {
        let document = preflight(&home, hold);
        assert_eq!(document["clear"], true, "{document}");
        assert_eq!(document["carriedOver"]["terminalJobCount"], 1);
    }
    assert_eq!(home.tree(), before);
}

#[test]
fn the_session_root_the_settings_select_is_proved_too() {
    let _turn = turn();
    let home = Home::new();
    home.minimal();
    let state = home.state();
    let custom = home.0.join("custom-sessions");
    directory(&custom);
    directory(&home.sessions());
    let jobs = arkdeck_hoststore::JobStore::open_state_root_owner(&state).unwrap();
    let settings = |bytes: &[u8]| {
        fs::write(state.join("session-storage.json"), bytes).unwrap();
        fs::set_permissions(
            state.join("session-storage.json"),
            fs::Permissions::from_mode(0o600),
        )
        .unwrap();
    };
    let mut selected = serde_json::to_vec(&json!({
        "schemaVersion": "arkdeck.session-storage-store/1", "generation": 2,
        "rootKind": "custom", "rootPath": custom.to_str().unwrap(),
        "policy": {"totalQuotaBytes": 21474836480_u64, "safetyMarginBytes": 2147483648_u64,
            "retentionDays": 90}}))
    .unwrap();
    selected.push(b'\n');
    settings(selected.as_slice());
    let stray = "job-0000000000000000000000000000c002";
    let location = format!("2026/09/session-{stray}");
    home.stopped_publication(&custom, &location, stray);
    let refusal = jobs
        .require_mutation_state(&state, std::slice::from_ref(&custom))
        .unwrap_err();
    let document = preflight(&home, false);
    assert_eq!(
        blocks(&document),
        [
            json!({"kind": "retainedSessions", "sessionsRoot": custom.to_str().unwrap(),
            "code": refusal.code, "message": refusal.message})
        ],
        "{document}"
    );
    // Settings that cannot be read are named, and the default root is still
    // proved.
    settings(b"not the settings".as_slice());
    let default = home.sessions();
    home.stopped_publication(&default, &location, stray);
    let document = preflight(&home, false);
    let refusal = jobs.require_mutation_state(&state, &[]).unwrap_err();
    assert_eq!(
        blocks(&document),
        [
            json!({"kind": "retainedSessions", "sessionsRoot": default.to_str().unwrap(),
                "code": refusal.code, "message": refusal.message}),
            json!({"kind": "unreadable", "source": "sessionStorage",
                "reason": "Session storage is unavailable or unsafe"}),
        ],
        "{document}"
    );
}
