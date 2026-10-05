//! `job archive preview|apply` end to end on Windows (TASK-XPA-005): the
//! real signed `arkdeck.exe` previews and archives a quiescent Job against
//! the signed test daemon (`signed_daemon.rs`), the production Windows
//! development root composition, at a fixed clock.
//!
//! No Swift oracle records the archive (Swift retired before #2468), so the
//! reference is the macOS Rust Runtime's answers
//! (`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/
//! job.archive.jsonl` and `job.archive.preview.jsonl`, recorded by
//! `arkdeck-hoststore`'s `job_archive` tests over the same Job). The Job is
//! that Job: the `job-reconcile-analyzer` record, its journal written as
//! those tests write it (created, running, one confirmed host-only step,
//! `waitingForRecovery`), seeded below the development root's Job state
//! before the daemon starts. Every answer equals the macOS one except
//! `reviewSha256` and `manifestSha256`, which digest this host's own durable
//! record, journal and Session manifest bytes (they differ between hosts in
//! the owner's own tests too); each is checked by its use instead: a stale
//! review refused, the current one accepted, the manifest on disk. Host
//! tests only: nothing reaches a device or an installed Runtime.
use crate::signed_daemon::{self, SignedDaemon, fixtures, signed_copy, temporary};
use arkdeck_hoststore::job_journal_events::{self as events, Envelope};
use arkdeck_hoststore::{JobRecord, JobStore, JournalWriter};
use arkdeck_platform::HostDirectory;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The Job the macOS frames archived.
const ID: &str = "job-082b8363fce0462b4571a62147751099";
/// Its journal's instant, and the daemon's clock.
const AT: &str = "2026-10-04T06:00:00Z";

/// The macOS frames' Job, seeded below `root`'s Job state as the owner's
/// `job_archive` tests write it (`Fixture::with_step`).
fn seed(root: &Path) {
    for path in [root.to_path_buf(), root.join("jobs-state")] {
        HostDirectory::open_or_create_private(&path).unwrap();
    }
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let bytes = std::fs::read(
        fixtures("job-reconcile-analyzer")
            .join("before/jobs")
            .join(ID)
            .join("job-record.json"),
    )
    .unwrap();
    let mut record = JobRecord::decode(&bytes).unwrap();
    jobs.admit(&record, &"a".repeat(64)).unwrap();
    let directory = root.join("jobs-state/jobs").join(ID);
    HostDirectory::open_or_create_private(&root.join("jobs-state/jobs")).unwrap();
    HostDirectory::open_or_create_private(&directory).unwrap();
    let mut writer = JournalWriter::open(&directory, true).unwrap();
    let env = |seq| Envelope {
        event_id: format!("event-{seq}"),
        sequence: seq,
        session_id: format!("session-{ID}"),
        job_id: ID.into(),
        timestamp: AT.into(),
    };
    writer
        .append(&events::job_created(
            &env(0),
            "execute",
            "standardAgent",
            "CORE-2.0.0",
        ))
        .unwrap();
    for (seq, from, to) in [(1, "queued", "preflight"), (2, "preflight", "running")] {
        writer
            .append(&events::state_transition(
                &env(seq),
                from,
                to,
                "fixture safe boundary",
                None,
            ))
            .unwrap();
    }
    let step = json!({"id":"extract-crash-signature", "kind":"runDeterministicAnalyzer", "effect":"hostOnly",
        "bindingRequirement":"none", "cancellation":"immediate", "compensationDescriptors":[],
        "arguments":{"analyzerRef":"crash-signature@1", "inputArtifactId":"ART-990a17a6b9ca251b17028e7c824f7b8b", "artifactId":"crash-signature.json"}});
    let target = events::Target {
        scope: "host".into(),
        target_id: "TGT-ORACLE".into(),
        connect_key: None,
        identity_snapshot_hash: None,
    };
    writer
        .append(&events::step_intent(&env(3), &step, &target, 1, None).unwrap())
        .unwrap();
    writer
        .append(&events::step_outcome(
            &env(4),
            "extract-crash-signature",
            1,
            "event-3",
            "succeeded",
            "confirmed",
            None,
            None,
        ))
        .unwrap();
    writer
        .append(&events::state_transition(
            &env(5),
            "running",
            "waitingForRecovery",
            "fixture safe boundary",
            None,
        ))
        .unwrap();
    record.state = "waitingForRecovery".into();
    jobs.persist(&record, AT).unwrap();
}

/// The macOS Runtime's recorded frames of `method`, in order.
fn frames(method: &str) -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames")
        .join(format!("{method}.jsonl"));
    std::fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// The first of `frames` that `test` accepts.
fn recorded(frames: &[Value], test: impl Fn(&Value) -> bool) -> Value {
    frames
        .iter()
        .find(|frame| test(frame))
        .expect("the macOS frame")
        .clone()
}

/// `answer` (a CLI result) equals the macOS `frame`'s result, its host-local
/// digests aside.
fn assert_macos(answer: &Value, frame: &Value) {
    let (mut ours, mut theirs) = (answer.clone(), frame["result"].clone());
    for value in [&mut ours, &mut theirs] {
        value["reviewSha256"] = Value::Null;
        if value["publication"].is_object() {
            value["publication"]["manifestSha256"] = Value::Null;
        }
    }
    assert_eq!(ours, theirs, "{answer}");
}

/// The Runtime's refusal behind a CLI envelope is the macOS `frame`'s.
fn assert_refused(status: Option<i32>, envelope: &Value, frame: &Value) {
    assert_ne!(status, Some(0), "{envelope}");
    assert_eq!(envelope["ok"], false, "{envelope}");
    assert_eq!(
        envelope["error"]["details"]["wireCode"], frame["error"]["code"],
        "{envelope}"
    );
    assert_eq!(
        envelope["error"]["message"], frame["error"]["message"],
        "{envelope}"
    );
}

/// Every `manifest.json` below `directory`.
fn manifests(directory: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for entry in std::fs::read_dir(directory).into_iter().flatten() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            found.extend(manifests(&path));
        } else if path.file_name().is_some_and(|name| name == "manifest.json") {
            found.push(path);
        }
    }
    found
}

#[test]
fn a_quiescent_job_is_archived_over_the_signed_test_daemon() {
    let _turn = crate::turn();
    let scratch = temporary("job-archive");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let (root, fake_root) = (scratch.join("state"), scratch.join("fake"));
    seed(&root);
    std::fs::create_dir_all(&fake_root).unwrap();
    let daemon = SignedDaemon::start_with(
        &executable,
        &pin,
        &root,
        &fixtures("observe-device"),
        &fake_root,
        &[(
            signed_daemon::CLOCK,
            format!("{AT}|2026-10-04T06:00:00.000Z"),
        )],
    );
    let previews = frames("job.archive.preview");
    let archives = frames("job.archive");

    // The preview: archivable, its last confirmed step the host-only one.
    let (status, preview) = daemon.cli(&["job", "archive", "preview", "--job", ID]);
    assert_eq!(status, Some(0), "{preview}");
    assert_eq!(preview["command"], "job.archive.preview", "{preview}");
    assert_macos(
        &preview["result"],
        &recorded(&previews, |frame| {
            frame["result"]["mode"] == "archive"
                && frame["result"]["lastConfirmedStepId"] == "extract-crash-signature"
        }),
    );
    let review = preview["result"]["reviewSha256"]
        .as_str()
        .unwrap()
        .to_owned();
    let apply = |review: &str| {
        daemon.cli(&[
            "job",
            "archive",
            "apply",
            "--job",
            ID,
            "--user-confirmation-id",
            "user-archive-fixture",
            "--expected-review-sha256",
            review,
        ])
    };

    // A review that is not the current one is refused, as macOS refuses it,
    // and nothing is archived.
    let stale = recorded(&archives, |frame| frame["ok"] == false);
    let (status, refused) = apply(stale["params"]["expectedReviewSha256"].as_str().unwrap());
    assert_refused(status, &refused, &stale);
    let (_, unchanged) = daemon.cli(&["job", "archive", "preview", "--job", ID]);
    assert_eq!(unchanged["result"], preview["result"], "{unchanged}");

    // The current review: archived, its Session published.
    let (status, archived) = apply(&review);
    assert_eq!(status, Some(0), "{archived}");
    assert_eq!(archived["command"], "job.archive.apply", "{archived}");
    assert_macos(
        &archived["result"],
        &recorded(&archives, |frame| {
            frame["result"]["sessionPublished"] == true
        }),
    );
    let published = manifests(&root.join("sessions"));
    assert_eq!(published.len(), 1, "{published:?}");
    let bytes = std::fs::read(&published[0]).unwrap();
    assert_eq!(
        archived["result"]["publication"]["manifestSha256"],
        arkdeck_contract::sha256_hex(&bytes),
        "the published manifest"
    );
    let manifest: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(manifest["sessionDisposition"], "archived", "{manifest}");
    assert_eq!(
        manifest["recovery"]["userConfirmation"]["confirmationId"],
        "user-archive-fixture"
    );
    assert_eq!(
        manifest["recovery"]["recoveryGuide"]["automaticRecoveryAvailable"],
        false
    );

    // Previewed again: only its publication is left to finish, and finishing
    // it again publishes nothing new.
    let (status, again) = daemon.cli(&["job", "archive", "preview", "--job", ID]);
    assert_eq!(status, Some(0), "{again}");
    assert_macos(
        &again["result"],
        &recorded(&previews, |frame| {
            frame["result"]["mode"] == "finishPublication"
        }),
    );
    let (status, finished) = apply(again["result"]["reviewSha256"].as_str().unwrap());
    assert_eq!(status, Some(0), "{finished}");
    assert_eq!(finished["result"], archived["result"], "{finished}");
    assert_eq!(manifests(&root.join("sessions")), published);

    // A Job that does not exist.
    let missing = recorded(&previews, |frame| frame["ok"] == false);
    let (status, absent) = daemon.cli(&[
        "job",
        "archive",
        "preview",
        "--job",
        missing["params"]["jobId"].as_str().unwrap(),
    ]);
    assert_refused(status, &absent, &missing);
    daemon.stop();
    let _ = std::fs::remove_dir_all(&scratch);

    let product = arkdeck_cli::machine_contracts::contract_products()
        .into_iter()
        .find(|product| product.relative_path == "cli-feature-coverage.json")
        .expect("the CLI renders its feature coverage");
    let coverage: Value = serde_json::from_slice(&product.bytes).unwrap();
    for feature in ["job.archive", "job.archive.preview"] {
        let entry = coverage["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["feature"] == feature)
            .unwrap();
        assert_eq!(
            entry["implementationStatusByPlatform"]["windows"],
            json!("implemented"),
            "{feature}"
        );
    }
}
