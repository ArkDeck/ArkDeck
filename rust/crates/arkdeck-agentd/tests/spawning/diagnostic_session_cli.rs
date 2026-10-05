//! GJ-1's interactive diagnostic session end to end on Windows
//! (TASK-XPA-005): the real signed `arkdeck.exe` submits and runs
//! `capture.diagnostic-session@1` against the signed test daemon
//! (`signed_daemon.rs`), and while the run records, reads the live session
//! (`diagnostics session status`), marks it (`diagnostics session mark`) and
//! stops it (`diagnostics session stop`), over the `diagnostic-session`
//! oracle (`rust/tests/fixtures/diagnostic-session/interactive.json`).
//!
//! The oracle was recorded by the Rust producer
//! `capture_diagnostics::diagnostic_session_publishes_host_marks_and_stops_after_an_unknown_anchor`
//! over the Swift fake device of `capture-diagnostics-trace`, its long
//! recording's start and finish answered in the observed ring lifecycle
//! vocabulary; the test daemon's fake answers so too
//! (`signed_daemon::RING_VOCABULARY`), at the oracle's fixed clock. The Job is
//! the oracle's (its identity follows from the request), and the Artifacts it
//! publishes are the oracle's: every inventory row the same, and each
//! document's bytes the same once the host instants the session read from the
//! wall clock (its arming, marks, stop and clock observation) are set aside.
//! A second session, whose device ring does not hold the anchor, is
//! interrupted before any dump, and a mark is then refused.
//!
//! Host tests only: no device, `hdc` or board is reached.
use crate::signed_daemon::{self, SignedDaemon, fixtures, temporary};
use serde_json::{Value, json};
use std::path::Path;
use std::time::{Duration, Instant};

/// The oracles' connect key, which the board's serial equals.
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
/// The Target the oracles adopted.
const TARGET: &str = "TGT-3ba3f5f43b92";

/// The producer's request, with its idempotency key `key`.
fn request(key: &str) -> Value {
    json!({
        "documentType":"runtime-operation-request", "schemaVersion":"1.0.0",
        "requestId":key, "idempotencyKey":key,
        "operation":{"id":"capture.diagnostic-session", "version":1},
        "target":{"targetId":TARGET, "expectedBindingRevision":1},
        "inputs":{"durationSeconds":3, "maximumMarkers":2, "traceCategories":["ohos"]},
        "requestedOutputs":["hardwareEvidence"]
    })
}

/// The calls the fake logged in `root`, each its arguments joined by spaces.
fn calls(root: &Path) -> Vec<String> {
    std::fs::read_to_string(root.join("hdc-invocations.log"))
        .unwrap_or_default()
        .lines()
        .map(|line| line.trim_end_matches('\u{1f}').replace('\u{1f}', " "))
        .collect()
}

/// `document` with the host instants and durations the session read from the
/// wall clock set aside (the oracle's producer ran at its own instants).
fn timeless(document: &mut Value) {
    match document {
        Value::Object(fields) => {
            for (key, value) in fields.iter_mut() {
                if key.ends_with("HostUTC")
                    || [
                        "elapsedNanoseconds",
                        "elapsedMs",
                        "offsetMs",
                        "offsetFromReadyMs",
                    ]
                    .contains(&key.as_str())
                {
                    *value = json!("<wall clock>");
                } else {
                    timeless(value);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(timeless),
        _ => {}
    }
}

/// Each feature's Windows status in the coverage this build renders.
fn assert_windows_status(features: &[&str], expected: &str) {
    let product = arkdeck_cli::machine_contracts::contract_products()
        .into_iter()
        .find(|product| product.relative_path == "cli-feature-coverage.json")
        .expect("the CLI renders its feature coverage");
    let coverage: Value = serde_json::from_slice(&product.bytes).unwrap();
    for feature in features {
        let statuses: Vec<&Value> = coverage["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| entry["feature"] == *feature)
            .map(|entry| &entry["implementationStatusByPlatform"]["windows"])
            .collect();
        assert!(
            !statuses.is_empty() && statuses.iter().all(|status| *status == expected),
            "{feature}: {statuses:?}"
        );
    }
}

/// Submits the producer's request under `key` through the CLI: its Job.
fn submit(daemon: &SignedDaemon, scratch: &Path, key: &str) -> String {
    let file = scratch.join(format!("{key}.json"));
    std::fs::write(&file, request(key).to_string()).unwrap();
    let (status, submitted) =
        daemon.cli(&["job", "submit", "--request-file", file.to_str().unwrap()]);
    assert_eq!(status, Some(0), "{submitted}");
    submitted["result"]["jobId"].as_str().unwrap().to_owned()
}

/// `diagnostics session status` until its state is `state`.
fn await_state(daemon: &SignedDaemon, job: &str, state: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let (status, envelope) = daemon.cli(&["diagnostics", "session", "status", "--job", job]);
        assert_eq!(status, Some(0), "{envelope}");
        assert_eq!(
            envelope["command"], "diagnostics.session.status",
            "{envelope}"
        );
        if envelope["result"]["state"] == state {
            return envelope["result"].clone();
        }
        assert!(
            Instant::now() < deadline,
            "the session never reached {state}: {envelope}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_diagnostic_session_is_marked_and_stopped_over_the_signed_test_daemon() {
    let _turn = crate::turn();
    let scratch = temporary("gj1-diagnostic-session");
    let Some((executable, pin)) = signed_daemon::signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let oracle: Value = serde_json::from_slice(
        &std::fs::read(fixtures("diagnostic-session").join("interactive.json")).unwrap(),
    )
    .unwrap();
    // The Swift fake device the producer ran over, its adopted Target and the
    // resources its Trace answers read.
    let fixture = fixtures("capture-diagnostics-trace");
    let (root, fake_root) = (scratch.join("state"), scratch.join("fake"));
    arkdeck_platform::HostDirectory::open_or_create_private(&root.join("targets-state")).unwrap();
    arkdeck_platform::HostDirectory::open(&root.join("targets-state"))
        .unwrap()
        .create_document(
            "targets.json",
            &std::fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        )
        .unwrap();
    std::fs::create_dir_all(fake_root.join("resources")).unwrap();
    for resource in std::fs::read_dir(fixture.join("resources")).unwrap() {
        let resource = resource.unwrap().path();
        std::fs::copy(
            &resource,
            fake_root
                .join("resources")
                .join(resource.file_name().unwrap()),
        )
        .unwrap();
    }
    let daemon = SignedDaemon::start_with(
        &executable,
        &pin,
        &root,
        &fixture,
        &fake_root,
        &[
            (signed_daemon::BOARD, KEY.to_owned()),
            (
                signed_daemon::MUTATION_ROOT,
                root.join("jobs-state").to_str().unwrap().to_owned(),
            ),
            (
                signed_daemon::CLOCK,
                "2026-09-14T00:00:00Z|2026-09-14T00:00:00.000Z".to_owned(),
            ),
            (signed_daemon::RING_VOCABULARY, "1".to_owned()),
        ],
    );

    // The oracle's session: submitted, run, marked once while it records,
    // then stopped.
    let job = submit(&daemon, &scratch, "interactive-fixture");
    assert_eq!(job, oracle["jobId"].as_str().unwrap(), "the oracle's Job");
    let running = daemon.cli_running(&["job", "run", "--job", &job]);
    let recording = await_state(&daemon, &job, "recording");
    assert_eq!(recording["jobId"], job.as_str(), "{recording}");
    assert_eq!(recording["markers"], json!([]), "{recording}");
    let (status, marked) = daemon.cli(&[
        "diagnostics",
        "session",
        "mark",
        "--job",
        &job,
        "--marker-id",
        "problem-observed",
    ]);
    assert_eq!(status, Some(0), "{marked}");
    assert_eq!(marked["command"], "diagnostics.session.mark", "{marked}");
    let markers = marked["result"]["markers"].as_array().unwrap();
    assert_eq!(markers.len(), 1, "{marked}");
    assert_eq!(markers[0]["markerId"], "problem-observed", "{marked}");
    let (status, stopped) = daemon.cli(&["diagnostics", "session", "stop", "--job", &job]);
    assert_eq!(status, Some(0), "{stopped}");
    assert_eq!(stopped["command"], "diagnostics.session.stop", "{stopped}");
    let (status, ran) = running.finish();
    assert_eq!(status, Some(0), "{ran}");
    let (status, ended) = daemon.cli(&["diagnostics", "session", "status", "--job", &job]);
    assert_eq!(status, Some(0), "{ended}");
    assert_eq!(ended["result"]["jobState"], "succeeded", "{ended}");
    assert!(
        ended["result"].get("clockObservation").is_none(),
        "the live control answer is closed: {ended}"
    );
    // A stopped session takes no mark.
    let (status, late) = daemon.cli(&[
        "diagnostics",
        "session",
        "mark",
        "--job",
        &job,
        "--marker-id",
        "too-late",
    ]);
    assert_ne!(status, Some(0), "{late}");
    assert_eq!(late["ok"], false, "{late}");

    // Its Artifacts, read through the CLI, are the oracle's: each row and its
    // bytes Swift's, except the two documents that hold the session's
    // wall-clock instants, which are the oracle's once those are set aside
    // (and so is their row, but for the identity and digest their bytes
    // derive).
    let (status, listed) = daemon.cli(&["artifact", "list", "--job", &job, "--page-size", "1000"]);
    assert_eq!(status, Some(0), "{listed}");
    let by_name = |rows: &[Value]| -> Vec<Value> {
        let mut rows = rows.to_vec();
        rows.sort_by(|left, right| left["name"].as_str().cmp(&right["name"].as_str()));
        rows
    };
    let rows = by_name(listed["result"]["items"].as_array().unwrap());
    let recorded = by_name(oracle["inventory"].as_array().unwrap());
    assert_eq!(
        rows.iter().map(|row| &row["name"]).collect::<Vec<_>>(),
        recorded.iter().map(|row| &row["name"]).collect::<Vec<_>>(),
        "the oracle's Artifacts"
    );
    let documents = oracle["documents"].as_object().unwrap();
    for (row, recorded) in rows.iter().zip(&recorded) {
        let name = row["name"].as_str().unwrap();
        let bytes = std::fs::read(
            root.join("artifacts")
                .join(&job)
                .join(row["artifactId"].as_str().unwrap()),
        )
        .unwrap();
        assert_eq!(
            row["artifactDigest"].as_str().unwrap(),
            arkdeck_contract::sha256_hex(&bytes),
            "{name}"
        );
        if !["markers.json", "diagnostic-session.json"].contains(&name) {
            assert_eq!(row, recorded, "{name}");
            if let Some(text) = documents.get(name) {
                assert_eq!(bytes, text.as_str().unwrap().as_bytes(), "{name}");
            }
            continue;
        }
        let mut ours: Value = serde_json::from_slice(&bytes).unwrap();
        let mut theirs: Value = serde_json::from_str(documents[name].as_str().unwrap()).unwrap();
        timeless(&mut ours);
        timeless(&mut theirs);
        assert_eq!(ours, theirs, "{name}");
        let (mut ours, mut theirs) = (row.clone(), recorded.clone());
        for key in ["artifactId", "artifactDigest", "byteCount", "lease"] {
            ours[key] = Value::Null;
            theirs[key] = Value::Null;
        }
        assert_eq!(ours, theirs, "{name}");
    }

    // A ring that does not hold the anchor: the session is interrupted after
    // the anchor's readback, nothing dumped, and takes no mark.
    std::fs::write(fake_root.join("hdc-mode"), "ringNotHeld\n").unwrap();
    let job = submit(&daemon, &scratch, "interactive-unknown-anchor");
    let before = calls(&fake_root).len();
    let (_, ran) = daemon.cli(&["job", "run", "--job", &job]);
    let interrupted = await_state(&daemon, &job, "interrupted");
    assert_eq!(interrupted["markers"], json!([]), "{ran} {interrupted}");
    let sent = calls(&fake_root)[before..].to_vec();
    assert!(
        sent.last()
            .is_some_and(|call| call.contains("grep -c ARKDECKANCHOR")),
        "nothing after the anchor's readback: {sent:?}"
    );
    let (status, refused) = daemon.cli(&[
        "diagnostics",
        "session",
        "mark",
        "--job",
        &job,
        "--marker-id",
        "problem-observed",
    ]);
    assert_ne!(status, Some(0), "{refused}");
    assert_eq!(refused["ok"], false, "{refused}");
    daemon.stop();
    let _ = std::fs::remove_dir_all(&scratch);
    assert_windows_status(
        &[
            "diagnostic.session.status",
            "diagnostic.session.mark",
            "diagnostic.session.stop",
        ],
        "implemented",
    );
    // The operation itself is reached through `job submit` alone: a generic
    // leaf, counted only under the shared generic leaves' ruling.
    assert_windows_status(&["capture.diagnostic-session@1"], "partial");
}
