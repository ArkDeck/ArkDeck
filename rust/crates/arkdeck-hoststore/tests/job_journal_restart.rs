//! A Job's Journal and its terminal Session across process deaths and
//! restarts, through the Rust owners on the durable host store (GJ-1 hops 5
//! and 9 at the owner level; on Windows the store is NTFS):
//!
//! - a writer killed inside an append leaves a torn tail that the next
//!   process repairs before it completes the Journal;
//! - the terminal Session Manifest one process publishes is read back by the
//!   next, write-once, and it ends the Journal.
//!
//! The recorded Job is `observe.device@1` (`rust/tests/fixtures/observe-device`,
//! recorded on macOS). This test spawns itself, so it has its own test binary
//! (see `job_journal_process_death.rs`).
#![cfg(any(target_os = "macos", windows))]

mod journal_scratch;

use arkdeck_hoststore::{JournalWriteError, JournalWriter, inspect_journal};
use arkdeck_platform::{DocumentPublishError, HostDirectory};
use journal_scratch::{Root, fixtures, recorded_facts, records};
use std::fs;
use std::path::PathBuf;
use std::process::Command;

const JOB: &str = "job-0f77f8c52864d676372962eccb17389c";
const SESSION: &str = "Sessions/2026/09/session-job-0f77f8c52864d676372962eccb17389c";
const MAXIMUM: usize = 16 * 1024 * 1024;

fn recorded_journal() -> Vec<u8> {
    fs::read(
        fixtures()
            .join("observe-device/store/jobs")
            .join(JOB)
            .join("journal.jsonl"),
    )
    .unwrap()
}
fn recorded_session(name: &str) -> Vec<u8> {
    fs::read(
        fixtures()
            .join("observe-device/sessions/2026/09/session-job-0f77f8c52864d676372962eccb17389c")
            .join(name),
    )
    .unwrap()
}
/// The first `count` records of `journal`, each with its line feed.
fn prefix(journal: &[u8], count: usize) -> &[u8] {
    let mut end = 0;
    for _ in 0..count {
        end += journal[end..]
            .iter()
            .position(|byte| *byte == b'\n')
            .unwrap()
            + 1;
    }
    &journal[..end]
}

/// Re-executed by the restart test: one process of the Job's life.
#[test]
fn journal_restart_child() {
    let Some(root) = std::env::var_os("ARKDECK_TEST_JOURNAL_RESTART_ROOT") else {
        return;
    };
    let root = PathBuf::from(root);
    let job = root.join("jobs").join(JOB);
    let journal = recorded_journal();
    let all = records(&journal);
    match std::env::var("ARKDECK_TEST_JOURNAL_RESTART_STAGE")
        .unwrap()
        .as_str()
    {
        // The Job's writer dies inside the append of record `torn`.
        "tear" => {
            let torn = all.len() / 2;
            let mut writer = JournalWriter::open(&job, true).unwrap();
            for record in &all[..torn] {
                writer.append(record).unwrap();
            }
            writer
                .append_with_checkpoint(&all[torn], |point| {
                    if format!("{point:?}") == "AfterPartialRecord" {
                        std::process::exit(86);
                    }
                })
                .unwrap();
            panic!("the partial record was not reached");
        }
        // The next process repairs and completes the Job's Journal, copies it
        // into its Session record by record, publishes the Session's terminal
        // Manifest and dies holding everything open.
        "publish" => {
            let mut writer = JournalWriter::open(&job, false).unwrap();
            let done = writer.facts().event_count;
            for record in &all[done..] {
                writer.append(record).unwrap();
            }
            let session = root.join(SESSION);
            let mut copy = JournalWriter::open(&session, true).unwrap();
            for record in &all {
                copy.append(record).unwrap();
            }
            // As the Session publication does: under the Session's terminal
            // lock, write-once.
            let directory = HostDirectory::open(&session).unwrap();
            let _terminal = directory.wait_lock(".manifest.lock", true).unwrap();
            directory
                .publish_exclusive("manifest.json", &recorded_session("manifest.json"))
                .unwrap();
            std::process::exit(87);
        }
        stage => panic!("unknown stage {stage}"),
    }
}

/// Runs one process of the Job's life to its end and requires its exit code.
fn run_child(root: &Root, stage: &str, code: i32) {
    let output = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "journal_restart_child", "--nocapture"])
        .env("ARKDECK_TEST_JOURNAL_RESTART_ROOT", &root.0)
        .env("ARKDECK_TEST_JOURNAL_RESTART_STAGE", stage)
        .output()
        .unwrap();
    assert_eq!(
        output.status.code(),
        Some(code),
        "{stage}: {}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn a_torn_journal_is_repaired_and_its_terminal_session_survives_restart() {
    let root = Root::new("restart");
    let job = root.private(&format!("jobs/{JOB}"));
    let session = root.private(SESSION);
    let journal = recorded_journal();
    let count = records(&journal).len();
    assert_eq!(recorded_session("journal.jsonl"), journal);
    let expected = recorded_facts(&root, "recorded", &journal);
    assert!(expected.finalized && !expected.has_torn_tail);

    // A writer killed inside an append leaves a byte prefix of the record.
    run_child(&root, "tear", 86);
    let torn = fs::read(job.join("journal.jsonl")).unwrap();
    let durable = prefix(&journal, count / 2);
    assert!(torn.len() > durable.len() && journal.starts_with(&torn));
    let facts = inspect_journal(&job).unwrap();
    assert!(facts.has_torn_tail);
    assert_eq!(facts.event_count, count / 2);

    // The next process repairs it, completes it and publishes the Session.
    run_child(&root, "publish", 87);

    // After that process's death, everything reads back as recorded.
    assert_eq!(fs::read(job.join("journal.jsonl")).unwrap(), journal);
    assert_eq!(inspect_journal(&job).unwrap(), expected);
    assert_eq!(fs::read(session.join("journal.jsonl")).unwrap(), journal);
    assert_eq!(inspect_journal(&session).unwrap(), expected);
    let directory = HostDirectory::open(&session).unwrap();
    let manifest = recorded_session("manifest.json");
    assert_eq!(directory.read("manifest.json", MAXIMUM).unwrap(), manifest);

    // The Manifest is write-once and ends the Session's Journal.
    assert!(matches!(
        directory.publish_exclusive("manifest.json", b"{}"),
        Err(DocumentPublishError::BeforePublication(error))
            if error.kind() == std::io::ErrorKind::AlreadyExists
    ));
    // Refused for the Manifest before any replay rule is consulted: the
    // record offered is the Journal's own last, well-formed record.
    let mut writer = JournalWriter::open(&session, false).unwrap();
    assert!(writer.facts().finalized);
    let last = records(&journal).pop().unwrap();
    assert!(matches!(
        writer.append(&last),
        Err(JournalWriteError::Refused(_))
    ));
    drop(writer);
    assert_eq!(directory.read("manifest.json", MAXIMUM).unwrap(), manifest);
    assert_eq!(fs::read(session.join("journal.jsonl")).unwrap(), journal);
}
