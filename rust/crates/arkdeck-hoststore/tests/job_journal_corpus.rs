//! Every Journal the fixtures record (Swift's and the Rust owners', recorded
//! on macOS), written again record by record by `JournalWriter` on this host's
//! durable store (NTFS on Windows), is the recorded bytes and replays to the
//! facts its recorded bytes replay to.
#![cfg(any(target_os = "macos", windows))]

mod journal_scratch;

use arkdeck_hoststore::{JournalEvent, JournalWriteError, JournalWriter, inspect_journal};
use journal_scratch::{Root, fixtures, records, write_private_file};
use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

/// Every Journal the fixtures hold, once per distinct content: each `.jsonl`
/// file whose first record is a `jobCreated`.
fn fixture_journals() -> Vec<(PathBuf, Vec<u8>)> {
    let (mut found, mut seen, mut pending) = (Vec::new(), BTreeSet::new(), vec![fixtures()]);
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                pending.push(path);
                continue;
            }
            if path
                .extension()
                .is_none_or(|extension| extension != "jsonl")
            {
                continue;
            }
            let bytes = fs::read(&path).unwrap();
            let first = bytes
                .split(|byte| *byte == b'\n')
                .next()
                .unwrap_or_default();
            if JournalEvent::decode(first).is_ok_and(|event| event.kind() == "jobCreated")
                && seen.insert(arkdeck_contract::sha256_hex(&bytes))
            {
                found.push((path, bytes));
            }
        }
    }
    found.sort();
    found
}

#[test]
fn every_recorded_journal_written_again_is_its_bytes_and_replays_to_its_facts() {
    let root = Root::new("corpus");
    let (mut written, mut appended, mut refused) = (0, 0, 0);
    for (index, (path, journal)) in fixture_journals().into_iter().enumerate() {
        let recorded = match inspect_journal(&{
            let directory = root.private(&format!("recorded-{index}"));
            write_private_file(&directory.join("journal.jsonl"), &journal);
            directory
        }) {
            Ok(facts) if !facts.has_torn_tail => facts,
            // Journals recorded torn or breaking the replay rules are the
            // refusal oracles' own inputs; the writer never produces them.
            // Any other refusal (the store's) fails the test.
            Ok(_) | Err(JournalWriteError::Invalid(_)) => {
                refused += 1;
                continue;
            }
            Err(error) => panic!("{}: {error}", path.display()),
        };
        let directory = root.private(&format!("written-{index}"));
        let mut writer = JournalWriter::open(&directory, true).unwrap();
        for record in records(&journal) {
            writer
                .append(&record)
                .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
            appended += 1;
        }
        drop(writer);
        assert!(
            fs::read(directory.join("journal.jsonl")).unwrap() == journal,
            "{}: the written bytes are not the recorded bytes",
            path.display()
        );
        assert_eq!(
            inspect_journal(&directory).unwrap(),
            recorded,
            "{}",
            path.display()
        );
        written += 1;
    }
    println!("{written} Journals ({appended} records) written; {refused} recorded torn or refused");
    // The corpus is every recorded journey's Journal, not a sample.
    assert!(written > 200 && appended > 2_500, "{written} {appended}");
    assert!(refused < written, "{refused} {written}");
}
