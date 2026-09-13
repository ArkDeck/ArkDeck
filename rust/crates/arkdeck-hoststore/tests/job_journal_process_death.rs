#![cfg(target_os = "macos")]
//! A process that dies at either durable write point leaves the old journal or
//! the new record, never a partial record that replay adopts.
//!
//! This test spawns a child process, so it has its own test binary: a child
//! spawned while another test thread closes and reopens a lock briefly holds
//! that thread's closed flock descriptor, and a non-blocking reopen then fails.
use arkdeck_hoststore::job_journal_events::{self as events, Envelope};
use arkdeck_hoststore::{JournalWriter, ReplayFacts};
use serde_json::Value;
use std::os::unix::fs::DirBuilderExt;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

struct Root(PathBuf);
impl Root {
    fn with(name: &str) -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("journal-process-death-{nonce:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        fs::write(
            path.join("journal.jsonl"),
            fixture(&format!("{name}.jsonl")),
        )
        .unwrap();
        Self(path)
    }
    fn bytes(&self) -> Vec<u8> {
        fs::read(self.0.join("journal.jsonl")).unwrap()
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn fixture(name: &str) -> Vec<u8> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/journal-writer")
        .join(name);
    fs::read(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
}
fn facts() -> ReplayFacts {
    serde_json::from_slice(&fixture("unknown.replay.json")).unwrap()
}
/// The `unknown` oracle's next record, as the writer's unit tests build it.
fn continuation() -> Value {
    events::state_transition(
        &Envelope {
            event_id: "evt-10".into(),
            sequence: 10,
            session_id: "session-rust-writer".into(),
            job_id: "job-rust-writer".into(),
            timestamp: "2026-09-13T00:00:10Z".into(),
        },
        "waitingForRecovery",
        "reconciling",
        "manualReconcile",
        None,
    )
}

/// Re-executed by `process_death_at_each_write_point_keeps_old_or_new`.
#[test]
fn journal_append_process_death_child() {
    let Some(path) = std::env::var_os("ARKDECK_TEST_JOURNAL_ROOT") else {
        return;
    };
    let stage = std::env::var("ARKDECK_TEST_JOURNAL_STAGE").unwrap();
    let mut writer = JournalWriter::open(Path::new(&path), false).unwrap();
    writer
        .append_with_checkpoint(&continuation(), |point| {
            if format!("{point:?}") == stage {
                std::process::exit(86);
            }
        })
        .unwrap();
    panic!("requested journal write point was not reached");
}

#[test]
fn process_death_at_each_write_point_keeps_old_or_new() {
    for stage in ["AfterPartialRecord", "AfterRecordSync"] {
        let root = Root::with("unknown");
        let golden = root.bytes();
        let result = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "journal_append_process_death_child"])
            .env("ARKDECK_TEST_JOURNAL_ROOT", &root.0)
            .env("ARKDECK_TEST_JOURNAL_STAGE", stage)
            .output()
            .unwrap();
        assert_eq!(result.status.code(), Some(86), "{stage}: {result:?}");
        let mut reopened = JournalWriter::open(&root.0, false).unwrap();
        let expected = facts().event_count;
        if stage == "AfterPartialRecord" {
            assert_eq!(root.bytes(), golden, "a partial record is never adopted");
            assert_eq!(reopened.facts(), facts());
            reopened.append(&continuation()).unwrap();
        } else {
            assert_eq!(reopened.facts().event_count, expected + 1);
            assert!(root.bytes().starts_with(&golden));
        }
    }
}
