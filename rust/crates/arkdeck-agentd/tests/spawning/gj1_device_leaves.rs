//! GJ-1's device leaves end to end on Windows (TASK-XPA-005): the real
//! signed `arkdeck.exe` runs `target observe` (`observe.device@1`) and
//! `diagnostics capture` (`capture.diagnostics@1`) against the signed test
//! daemon (`signed_daemon.rs`), which composes the production Windows
//! development root with the shared fake HDC's answers in process
//! (`oracle_fake.rs`) and a synthetic USB census naming the fixture's board.
//!
//! The Target is the one the Swift oracles adopted (`targets.json`), and the
//! fake answers as the oracle's driver. The CLI observes the board through
//! `device.observations` (proved by the census), submits and runs the Job,
//! reads its evidence and its Artifacts, and completes. The fake must then
//! have received, after the CLI's observation reads, exactly the calls the
//! oracle's Job made (`hdc-invocations.log`).
//!
//! The pause path is measured too. Without the board the executor pauses for
//! a reconnect and keeps its pending record in the paused run's state
//! directory: on Windows that is below the account's local application data
//! (`domain_leaves::state_directory`), owner-only. After the daemon is
//! restarted over the same root with the board attached, `agent resume
//! --resume-token` completes the run, and the record is removed. Host tests
//! only: no device, `hdc` or board is reached.
use crate::signed_daemon::{SignedDaemon, fixtures, signed_copy, temporary};
use arkdeck_platform::{HostDirectory, LocalEndpoint};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The oracles' connect key, which the board's serial equals.
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
/// The Target the oracles adopted.
const TARGET: &str = "TGT-3ba3f5f43b92";

/// A development root holding the oracle's adopted Target, and the fake's
/// own root, below `scratch`.
fn roots(scratch: &Path, fixture: &Path) -> (PathBuf, PathBuf) {
    let (root, fake_root) = (scratch.join("state"), scratch.join("fake"));
    HostDirectory::open_or_create_private(&root.join("targets-state")).unwrap();
    HostDirectory::open(&root.join("targets-state"))
        .unwrap()
        .create_document(
            "targets.json",
            &std::fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        )
        .unwrap();
    std::fs::create_dir_all(&fake_root).unwrap();
    (root, fake_root)
}

/// The calls a fake (or the oracle's driver) logged in `root`, each its
/// arguments joined by spaces.
fn calls(root: &Path) -> Vec<String> {
    std::fs::read_to_string(root.join("hdc-invocations.log"))
        .unwrap_or_default()
        .lines()
        .map(|line| line.trim_end_matches('\u{1f}').replace('\u{1f}', " "))
        .collect()
}

/// The paused runs' state directory of one test daemon's pipe (below this
/// account's local application data), removed when the test ends, whether
/// it passed or not.
struct PausedRuns(PathBuf);

impl Drop for PausedRuns {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The fake's calls since `before` were the CLI's observation reads, then
/// exactly the first `count` calls the oracle's driver recorded (its first
/// Job's).
fn assert_oracle_job(fake_root: &Path, before: usize, fixture: &Path, count: usize) {
    let seen = calls(fake_root)[before..].to_vec();
    let job: Vec<String> = calls(fixture).into_iter().take(count).collect();
    assert!(seen.len() >= job.len(), "{seen:?}");
    let observations = seen.len() - job.len();
    assert!(
        seen[..observations]
            .iter()
            .all(|call| call == "list targets -v"),
        "{seen:?}"
    );
    assert_eq!(seen[observations..], job[..], "the oracle's Job calls");
}

/// A completed domain leaf's receipt: the operation's Job, its evidence
/// observed on the oracle's device, every Artifact read back.
fn assert_completed(envelope: &Value, command: &str, operation: &str, artifacts: usize) {
    assert_eq!(envelope["ok"], true, "{envelope}");
    assert_eq!(envelope["command"], command, "{envelope}");
    let receipt = &envelope["result"];
    assert_eq!(receipt["operationReference"], operation, "{receipt}");
    assert_eq!(receipt["outcomeUnknown"], false, "{receipt}");
    let observation = &receipt["evidenceObservation"];
    assert_eq!(observation["targetId"], TARGET, "{receipt}");
    assert_eq!(observation["model"], "OpenHarmony Reference Device");
    assert_eq!(observation["firmware"], "OpenHarmony-4.1-release");
    let read = receipt["artifacts"].as_array().unwrap();
    assert_eq!(read.len(), artifacts, "{receipt}");
    assert!(
        read.iter()
            .all(|artifact| artifact["bytesVerified"] == true)
    );
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

#[test]
fn target_observe_pauses_resumes_and_completes_over_the_signed_test_daemon() {
    let _turn = crate::turn();
    let scratch = temporary("gj1-target-observe");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let fixture = fixtures("observe-device");
    let (root, fake_root) = roots(&scratch, &fixture);

    // No board: the observation proves nothing, and the run pauses for a
    // reconnect, its pending record kept owner-only.
    let daemon = SignedDaemon::start(&executable, &pin, &root, &fixture, &fake_root);
    let (status, paused) = daemon.cli(&["target", "observe", "--target", TARGET]);
    assert_eq!(status, Some(75), "{paused}");
    assert_eq!(paused["error"]["code"], "humanActionRequired", "{paused}");
    assert_eq!(paused["error"]["details"]["kind"], "physicalReconnect");
    let token = paused["error"]["details"]["resumeToken"]
        .as_str()
        .unwrap()
        .to_owned();
    let state = PausedRuns(arkdeck_cli::domain_leaves::state_directory(
        &LocalEndpoint::new(daemon.pipe()),
    ));
    let record = state.0.join(format!("{token}.json"));
    assert!(record.is_file(), "{}", record.display());
    HostDirectory::open(&state.0).expect("an owner-only state directory");
    assert_eq!(calls(&fake_root), ["list targets -v"], "nothing was run");
    daemon.stop();

    // The board attached and the daemon restarted over the same root: the
    // resumed run observes it, runs the Job and completes.
    let daemon =
        SignedDaemon::start_with_board(&executable, &pin, &root, &fixture, &fake_root, KEY);
    let before = calls(&fake_root).len();
    let (status, resumed) = daemon.cli(&["agent", "resume", "--resume-token", &token]);
    assert_eq!(status, Some(0), "{resumed}");
    assert_completed(&resumed, "agent.resume", "observe.device@1", 3);
    // The pause it resumed, resolved.
    let actions = resumed["result"]["humanActions"].as_array().unwrap();
    assert_eq!(actions.len(), 1, "{resumed}");
    assert_eq!(actions[0]["kind"], "physicalReconnect");
    assert_eq!(actions[0]["resumeToken"], token.as_str());
    assert!(actions[0]["resolvedAtUTC"].is_string(), "{resumed}");
    assert!(!record.exists(), "the pending record is removed");
    assert_oracle_job(&fake_root, before, &fixture, 5);

    // Run again directly: the observation, then exactly the oracle's Job.
    let before = calls(&fake_root).len();
    let (status, observed) = daemon.cli(&["target", "observe", "--target", TARGET]);
    assert_eq!(status, Some(0), "{observed}");
    assert_completed(&observed, "target.observe", "observe.device@1", 3);
    assert_eq!(observed["result"]["humanActions"], json!([]), "{observed}");
    assert_oracle_job(&fake_root, before, &fixture, 5);
    daemon.stop();
    let _ = std::fs::remove_dir_all(&scratch);
    // `target observe` is the operation's one leaf.
    assert_windows_status(&["observe.device@1"], "implemented");
}

#[test]
fn diagnostics_capture_completes_over_the_signed_test_daemon() {
    let _turn = crate::turn();
    let scratch = temporary("gj1-diagnostics-capture");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let fixture = fixtures("capture-diagnostics");
    let (root, fake_root) = roots(&scratch, &fixture);
    // The oracle's captured request's inputs.
    let inputs = scratch.join("inputs.json");
    std::fs::write(&inputs, br#"{"durationSeconds":5}"#).unwrap();
    let daemon =
        SignedDaemon::start_with_board(&executable, &pin, &root, &fixture, &fake_root, KEY);
    let (status, captured) = daemon.cli(&[
        "diagnostics",
        "capture",
        "--target",
        TARGET,
        "--inputs-file",
        inputs.to_str().unwrap(),
    ]);
    assert_eq!(status, Some(0), "{captured}");
    assert_completed(&captured, "diagnostics.capture", "capture.diagnostics@1", 6);
    assert_eq!(captured["result"]["humanActions"], json!([]), "{captured}");
    assert_oracle_job(&fake_root, 0, &fixture, 6);
    daemon.stop();
    let _ = std::fs::remove_dir_all(&scratch);
    assert_windows_status(&["capture.diagnostics@1"], "implemented");
}

/// The other leaves of `capture.diagnostics@1`, each a preset of its inputs
/// (`domain_leaves::preset`), against one signed test daemon whose fake HDC
/// answers as the Trace legs' oracle (`capture-diagnostics-trace`), the table
/// that answers every leg: `screen capture`, `ui-dump capture` and
/// `trace capture` write, read back, receive and remove a provider-owned
/// file under the Runtime's mutation authority; `ui-dump component-detail`
/// and `debug logs` only read. Each completes with no pause, every Artifact
/// read back, its legs' commands sent, and every owned file it wrote on the
/// device removed. The test daemon's device mutations are proved against its
/// own Job state (`MUTATION_ROOT`, as #2505's replays prove theirs): a
/// development root otherwise names the account's, and refuses them.
#[test]
fn every_capture_preset_completes_over_the_signed_test_daemon() {
    let _turn = crate::turn();
    let scratch = temporary("gj1-presets");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let fixture = fixtures("capture-diagnostics-trace");
    let (root, fake_root) = roots(&scratch, &fixture);
    // The resources the Trace legs' answers read.
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
            (crate::signed_daemon::BOARD, KEY.to_owned()),
            (
                crate::signed_daemon::MUTATION_ROOT,
                root.join("jobs-state").to_str().unwrap().to_owned(),
            ),
        ],
    );
    let shell = format!("-t {KEY} shell ");
    for (leaf, inputs, artifacts, legs) in [
        (
            ["screen", "capture"],
            "{}",
            5,
            vec!["snapshot_display -t png -f /data/local/tmp/arkdeck-"],
        ),
        (
            ["ui-dump", "capture"],
            "{}",
            7,
            vec![
                "hidumper -s WindowManagerService -a -a",
                "uitest dumpLayout -p /data/local/tmp/arkdeck-",
                "snapshot_display -t png -f /data/local/tmp/arkdeck-",
            ],
        ),
        (
            ["ui-dump", "component-detail"],
            r#"{"windowId":"7","componentId":"42"}"#,
            5,
            vec!["hidumper -s WindowManagerService -a -w 7 -element -lastpage 42"],
        ),
        (
            ["debug", "logs"],
            r#"{"durationSeconds":5}"#,
            5,
            vec!["hilog -x"],
        ),
        (
            ["trace", "capture"],
            r#"{"durationSeconds":5,"traceCategories":["ability","ace","graphic"],"traceBufferKB":8192}"#,
            6,
            vec!["hitrace -t 5 -b 8192 ability ace graphic -o /data/local/tmp/arkdeck-"],
        ),
    ] {
        let file = scratch.join("inputs.json");
        std::fs::write(&file, inputs).unwrap();
        let before = calls(&fake_root).len();
        let mut arguments = leaf.to_vec();
        arguments.extend(["--target", TARGET, "--inputs-file", file.to_str().unwrap()]);
        let (status, envelope) = daemon.cli(&arguments);
        assert_eq!(status, Some(0), "{leaf:?}: {envelope}");
        assert_completed(
            &envelope,
            &leaf.join("."),
            "capture.diagnostics@1",
            artifacts,
        );
        assert_eq!(envelope["result"]["humanActions"], json!([]), "{envelope}");
        let sent = calls(&fake_root)[before..].to_vec();
        for leg in legs {
            let command = format!("{shell}{leg}");
            assert!(
                sent.iter().any(|call| call.starts_with(&command)),
                "{leaf:?} sent no {command}: {sent:?}"
            );
        }
        // Every owned file a leg wrote on the device was received and then
        // removed: none is left in the fake's device storage.
        for call in sent.iter().filter(|call| call.contains("-owned.")) {
            let owned = call
                .split(' ')
                .find(|word| word.starts_with("/data/local/tmp/arkdeck-"))
                .unwrap();
            assert!(
                sent.contains(&format!("{shell}rm -f {owned}")),
                "{leaf:?} left {owned}: {sent:?}"
            );
        }
        let device = fake_root.join("device-tmp");
        let left: Vec<_> = std::fs::read_dir(&device)
            .map(|entries| entries.map(|entry| entry.unwrap().file_name()).collect())
            .unwrap_or_default();
        assert!(left.is_empty(), "{leaf:?} left {left:?} on the device");
    }
    daemon.stop();
    let _ = std::fs::remove_dir_all(&scratch);
    // Every leaf of the operation is measured now.
    assert_windows_status(&["capture.diagnostics@1"], "implemented");
}
