//! A retained Session that holds its identity and no Manifest, as a
//! publication that stopped short of it leaves, is passed over by the
//! continuity proof only as the durable record of a Job this Runtime holds
//! proves it (TASK-XPA-014). The Swift device reconcile oracle's replay
//! (`rust/tests/fixtures/device-reconcile`) leaves one: the observation Job
//! whose publication failed on its Manifest (`storageUnavailable`), its whole
//! Journal, outcome audit and locks copied. What it leaves passes as it
//! always did: the whole Journal replays clean. The Sessions a failure
//! earlier in the publication leaves are refused by the scan, and pass only
//! as that record accounts for them; anything else stays refused, the
//! refusal naming the Session.
#![cfg(target_os = "macos")]

mod support;

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use support::debug_hap;
use support::reconcile::Daemon;

const JOB: &str = "job-4bd04c47bf05674cb836addf3ffee919";

/// A change to the failed publication's Session, given the Job's whole
/// Journal.
type Change = fn(&Path, &[u8]);

/// The device reconcile oracle replayed through its reconciles: the failed
/// publication's Session is left in the Sessions root.
fn replayed() -> Daemon {
    let mut daemon = Daemon::open("device-reconcile");
    let cases = support::document(&daemon.fixture, "cases.json");
    let exchanges = cases["exchanges"].as_array().unwrap();
    for exchange in exchanges
        .iter()
        .take_while(|exchange| exchange["method"] != "job.reconcile")
    {
        daemon.answer(&daemon.dispatch, exchange);
    }
    for _ in cases["starts"].as_array().unwrap() {
        daemon.restart();
    }
    for exchange in exchanges
        .iter()
        .filter(|exchange| exchange["method"] == "job.reconcile")
    {
        daemon.answer(&daemon.dispatch, exchange);
    }
    daemon
}

/// Every file below `path`, relative, with its bytes.
fn files(path: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    let mut found = Vec::new();
    let mut pending = vec![path.to_path_buf()];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).unwrap() {
            let entry = entry.unwrap().path();
            if entry.is_dir() {
                pending.push(entry);
            } else {
                found.push((
                    entry.strip_prefix(path).unwrap().to_path_buf(),
                    fs::read(&entry).unwrap(),
                ));
            }
        }
    }
    found.sort();
    found
}

/// What the continuity proof answers over the Sessions root: the proof
/// alone (`require_retained_sessions`), a device mutation's
/// (`require_mutation_state`) and the cutover preflight's, which reads the
/// Job store without its owner (`cutover_retained_sessions`); all three must
/// agree.
fn proof(daemon: &Daemon) -> Result<(), String> {
    let jobs = &daemon.stores().jobs;
    let sessions = daemon.root.join("Sessions");
    let alone = jobs.require_retained_sessions(&sessions);
    let cutover = arkdeck_hoststore::cutover_retained_sessions(&daemon.default_root, &sessions);
    let whole = jobs.require_mutation_state(&daemon.default_root, &[sessions]);
    assert_eq!(alone, whole);
    assert_eq!(cutover, alone);
    alone.map_err(|refusal| format!("{}: {}", refusal.code, refusal.message))
}

fn refusal(location: &str) -> Result<(), String> {
    Err(format!(
        "recordUnreadable: Runtime mutation state continuity cannot be proved: retained Session \
         {location} has no Manifest and no failed publication of this Runtime accounts for it; \
         runtime storage status and session cleanup name it; move it out of the Session root \
         once reviewed; original state is preserved"
    ))
}

#[test]
fn a_failed_publication_s_session_passes_only_as_its_job_s_record_proves_it() {
    let _lock = debug_hap::exclusive();
    let daemon = replayed();
    let sessions = daemon.root.join("Sessions");
    let relative = format!("2026/09/session-{JOB}");
    let session = sessions.join(&relative);
    let accounted = |daemon: &Daemon| {
        daemon
            .stores()
            .jobs
            .failed_publication_accounts_for(&sessions, ["2026", "09", &format!("session-{JOB}")])
    };
    // What the failed publication left: no Manifest, its whole Journal, the
    // outcome audit and the locks. The record accounts for it, and the scan
    // passes it as it always did.
    assert!(!session.join("manifest.json").exists());
    let record: Value = serde_json::from_slice(
        &fs::read(
            daemon
                .default_root
                .join(format!("jobs/{JOB}/job-record.json")),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(
        record["sessionPublicationRecord"]["failure"]["code"],
        "storageUnavailable"
    );
    assert!(accounted(&daemon));
    assert_eq!(proof(&daemon), Ok(()));
    let left = files(&session);
    let restore = || {
        fs::remove_dir_all(&session).unwrap();
        fs::create_dir(&session).unwrap();
        support::chmod(&session, 0o700);
        for directory in [
            "audit",
            "artifacts",
            "artifacts/raw",
            "artifacts/derived",
            "artifacts/partial",
        ] {
            fs::create_dir(session.join(directory)).unwrap();
            support::chmod(&session.join(directory), 0o700);
        }
        for (path, bytes) in &left {
            fs::write(session.join(path), bytes).unwrap();
            support::chmod(&session.join(path), 0o600);
        }
    };
    let journal = session.join("journal.jsonl");
    let whole = fs::read(&journal).unwrap();

    // A copy stopped mid-record: a torn tail, which the scan refuses, and
    // which the record accounts for once nothing copied after it is there.
    fs::remove_file(session.join("audit/session.jsonl")).unwrap();
    for (path, _) in &left {
        if path.starts_with("artifacts/partial") {
            fs::remove_file(session.join(path)).unwrap();
        }
    }
    fs::write(&journal, &whole[..whole.len() - 20]).unwrap();
    assert!(accounted(&daemon));
    assert_eq!(proof(&daemon), Ok(()));

    // Stopped before the Journal was copied: the identity and the
    // directories alone.
    fs::remove_file(&journal).unwrap();
    fs::remove_file(session.join(".manifest.lock")).unwrap();
    assert!(accounted(&daemon));
    assert_eq!(proof(&daemon), Ok(()));

    // Each of these the record does not account for, and the scan refuses,
    // naming the Session.
    let unaccounted: [(&str, Change); 7] = [
        ("a file the publication never writes", |session, _| {
            fs::write(session.join("notes.txt"), b"x").unwrap();
            support::chmod(&session.join("notes.txt"), 0o600);
        }),
        (
            "an Artifact in a directory the publication leaves empty",
            |session, _| {
                fs::write(session.join("artifacts/raw/payload"), b"x").unwrap();
                support::chmod(&session.join("artifacts/raw/payload"), 0o600);
            },
        ),
        ("a Journal that is not the Job's", |session, whole| {
            let mut other = whole[..whole.len() - 20].to_vec();
            other[10] ^= 1;
            fs::write(session.join("journal.jsonl"), other).unwrap();
            support::chmod(&session.join("journal.jsonl"), 0o600);
        }),
        (
            "an outcome audit before the whole Journal is copied",
            |session, whole| {
                fs::write(session.join("journal.jsonl"), &whole[..whole.len() - 20]).unwrap();
                support::chmod(&session.join("journal.jsonl"), 0o600);
                fs::write(session.join("audit/session.jsonl"), b"{}\n").unwrap();
                support::chmod(&session.join("audit/session.jsonl"), 0o600);
            },
        ),
        ("an identity that is not canonical", |session, _| {
            let path = session.join(".session-identity.json");
            let mut identity = fs::read(&path).unwrap();
            identity.push(b'\n');
            fs::write(&path, identity).unwrap();
        }),
        ("an identity naming another Job", |session, _| {
            fs::write(
                session.join(".session-identity.json"),
                br#"{"jobId":"job-a69eb4aba20a4b71f8791d322cac2cf6","schemaVersion":"1.0.0","sessionId":"session-job-a69eb4aba20a4b71f8791d322cac2cf6"}"#,
            )
            .unwrap();
        }),
        ("a lock that is not empty", |session, whole| {
            fs::write(session.join("journal.jsonl"), &whole[..whole.len() - 20]).unwrap();
            support::chmod(&session.join("journal.jsonl"), 0o600);
            fs::write(session.join(".manifest.lock"), b"x").unwrap();
            support::chmod(&session.join(".manifest.lock"), 0o600);
        }),
    ];
    for (case, change) in unaccounted {
        restore();
        fs::remove_file(session.join("audit/session.jsonl")).unwrap();
        for (path, _) in &left {
            if path.starts_with("artifacts/partial") {
                fs::remove_file(session.join(path)).unwrap();
            }
        }
        fs::remove_file(&journal).unwrap();
        change(&session, &whole);
        assert!(!accounted(&daemon), "{case}");
        assert_eq!(proof(&daemon), refusal(&relative), "{case}");
    }

    // A Job whose publication did not fail accounts for nothing: the
    // published observation's Session, cut back to exactly what a failure
    // before its Journal leaves, its Manifest moved aside. Only its Job's
    // record, which keeps a receipt, tells it apart.
    restore();
    assert_eq!(proof(&daemon), Ok(()));
    let published = fs::read_dir(sessions.join("2026/09"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .find(|name| *name != format!("session-{JOB}"))
        .unwrap();
    let other = sessions.join("2026/09").join(&published);
    fs::rename(
        other.join("manifest.json"),
        daemon.root.join("manifest.json"),
    )
    .unwrap();
    for (path, _) in files(&other) {
        if path != Path::new(".session-identity.json") {
            fs::remove_file(other.join(path)).unwrap();
        }
    }
    let record: Value = serde_json::from_slice(
        &fs::read(daemon.default_root.join(format!(
            "jobs/{}/job-record.json",
            &published["session-".len()..]
        )))
        .unwrap(),
    )
    .unwrap();
    assert!(record["sessionPublicationRecord"]["receipt"].is_object());
    assert!(
        !daemon
            .stores()
            .jobs
            .failed_publication_accounts_for(&sessions, ["2026", "09", &published])
    );
    assert_eq!(proof(&daemon), refusal(&format!("2026/09/{published}")));
}
