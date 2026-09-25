//! What copying a Job's Journal into its Session costs, now that a
//! publication holds the Session storage lock while it copies (TASK-XPA-014).
//! A measurement, not a check: `#[ignore]`d, run on a quiet host with
//! `cargo test -p arkdeck-hoststore --test session_publication_cost -- --ignored --nocapture`.
//!
//! The longest Journal the recorded journeys leave (44 records, the
//! diagnostics capture with a trace) is copied 20 times into a fresh
//! directory by the writer a publication copies with, record by record and
//! each durable before the next, as the publication's step 6 does. Every
//! append takes the directory's Manifest lock, writes the record, and
//! synchronizes the file and the directory; its cost does not depend on how
//! long the Journal already is.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_hoststore::JournalWriter;
use serde_json::Value;
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::time::{Duration, Instant};

#[test]
#[ignore = "a measurement for a quiet host"]
fn copying_a_journal_into_its_session_costs() {
    let journal = support::fixture("capture-diagnostics-trace")
        .join("store/jobs/job-2ba1bd5a231273e388689a61f209280c/journal.jsonl");
    let events: Vec<Value> = fs::read_to_string(&journal)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
    let root = std::env::temp_dir()
        .canonicalize()
        .unwrap()
        .join(format!("arkdeck-journal-copy-{nonce:032x}"));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    let (mut appends, mut copies) = (Vec::new(), Vec::new());
    for copy in 0..20 {
        let directory = root.join(format!("session-{copy}"));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
        let started = Instant::now();
        let mut writer = JournalWriter::open(&directory, true).unwrap();
        for event in &events {
            let append = Instant::now();
            writer.append(event).unwrap();
            appends.push(append.elapsed());
        }
        copies.push(started.elapsed());
        assert_eq!(
            fs::read(directory.join("journal.jsonl")).unwrap(),
            fs::read(&journal).unwrap()
        );
    }
    fs::remove_dir_all(&root).unwrap();
    let summary = |name: &str, mut samples: Vec<Duration>| {
        samples.sort();
        let at = |fraction: f64| samples[((samples.len() - 1) as f64 * fraction) as usize];
        println!(
            "{name}: n={} min={:?} median={:?} p95={:?} max={:?}",
            samples.len(),
            samples[0],
            at(0.5),
            at(0.95),
            samples[samples.len() - 1]
        );
    };
    println!(
        "journal: {} records, {} bytes",
        events.len(),
        fs::metadata(&journal).unwrap().len()
    );
    summary("one durable append", appends);
    summary("the whole copy", copies);
}
