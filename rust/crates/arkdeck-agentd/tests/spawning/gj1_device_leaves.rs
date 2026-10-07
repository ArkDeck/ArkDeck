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

use crate::support::catalog_lineage;

/// The oracles' connect key, which the board's serial equals.
pub(crate) const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
/// The Target the oracles adopted.
pub(crate) const TARGET: &str = "TGT-3ba3f5f43b92";

// These immutable Swift payloads are expectations, never seeds or authority.
// Only their typed top-level Catalog field changes for a fresh observation.
const OBSERVE_PAYLOADS: [(&str, &str, &str, usize); 3] = [
    (
        "ART-425d5127b8c74cc6c7c05ef4cb1e5f1c",
        "tool-facts.json",
        "9f6f75c195377b11dec88b5682df98ce3e8ee4222ef646a19c7791a244773766",
        240,
    ),
    (
        "ART-67508a7fd890cb7f31821eab538280a5",
        "device-facts.json",
        "6761aae97e4209feb39653e1e6eb7dc9d1c44b5ebd27ad44e2951f3face9917d",
        457,
    ),
    (
        "ART-d62fbafa7e5d327d9a28e8b61aa880bb",
        "binding-snapshot.json",
        "73de7718e8b3c16e0096f242686f1a6e4febf3adec50a4c9440c3816e853bc91",
        529,
    ),
];

fn current_observe_payload(index: usize, frozen: &[u8]) -> Result<Vec<u8>, String> {
    let (_, name, digest, count) = OBSERVE_PAYLOADS.get(index).ok_or("unknown payload")?;
    if frozen.len() != *count || arkdeck_contract::sha256_hex(frozen) != *digest {
        return Err("immutable observation payload changed".into());
    }
    let old: Value = serde_json::from_slice(frozen).map_err(|_| "observation JSON")?;
    if old["catalogDigest"] != catalog_lineage::OLD
        || old["operation"] != "observe.device@1"
        || old["artifact"] != *name
    {
        return Err("different observation schema".into());
    }
    let text = std::str::from_utf8(frozen).map_err(|_| "observation UTF-8")?;
    let from = format!("\"catalogDigest\" : \"{}\"", catalog_lineage::OLD);
    if text.matches(&from).count() != 1 {
        return Err("nonunique Catalog field".into());
    }
    let to = format!("\"catalogDigest\" : \"{}\"", catalog_lineage::CURRENT);
    let current = text.replacen(&from, &to, 1).into_bytes();
    let actual: Value = serde_json::from_slice(&current).map_err(|_| "derived observation JSON")?;
    let mut expected = old;
    expected["catalogDigest"] = json!(catalog_lineage::CURRENT);
    if actual != expected || current.len() != frozen.len() {
        return Err("a non-Catalog observation field changed".into());
    }
    Ok(current)
}

fn current_observe_artifacts(fixture: &Path, completed: &Value) -> Value {
    let lineage = catalog_lineage::Lineage::frozen().unwrap();
    lineage.operation("observe.device@1").unwrap();
    lineage
        .assert_catalog_view_sources(
            &Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Catalog/operations"),
            arkdeck_contract::CATALOG_DIGEST,
        )
        .unwrap();
    let cases = std::fs::read(fixture.join("cases.json")).unwrap();
    assert_eq!(
        arkdeck_contract::sha256_hex(&cases),
        "275d9c9428f68a9aa69d2173b8cea2aa404d8e19619d540547cfff6100929669"
    );
    if arkdeck_contract::CATALOG_DIGEST == catalog_lineage::OLD {
        return completed["artifacts"].clone();
    }
    assert_eq!(arkdeck_contract::CATALOG_DIGEST, catalog_lineage::CURRENT);
    let mut artifacts = completed["artifacts"].clone();
    let rows = artifacts.as_array_mut().unwrap();
    assert_eq!(rows.len(), OBSERVE_PAYLOADS.len());
    let job = "job-d166d1a72b51eb3b14528dae5cac37ee";
    for (index, ((id, name, digest, count), row)) in
        OBSERVE_PAYLOADS.iter().zip(rows.iter_mut()).enumerate()
    {
        assert_eq!(row["sha256"], *digest);
        assert_eq!(row["byteCount"], *count);
        assert_eq!(row["bytesVerified"], true);
        assert_eq!(row["reference"], format!("arkdeck-artifact://{job}/{id}"));
        // Reproduce the frozen identity first using the unchanged publisher's
        // complete job/name/payload-digest material; never learn an actual ID.
        let old_identity =
            arkdeck_contract::sha256_hex(format!("{job}\0{name}\0{digest}").as_bytes());
        assert_eq!(*id, format!("ART-{}", &old_identity[..32]));
        let path = fixture
            .join("artifacts/job-d166d1a72b51eb3b14528dae5cac37ee")
            .join(id);
        let frozen = std::fs::read(path).unwrap();
        let current = current_observe_payload(index, &frozen).unwrap();
        let current_digest = arkdeck_contract::sha256_hex(&current);
        let current_identity =
            arkdeck_contract::sha256_hex(format!("{job}\0{name}\0{current_digest}").as_bytes());
        row["reference"] = json!(format!(
            "arkdeck-artifact://{job}/ART-{}",
            &current_identity[..32]
        ));
        row["sha256"] = json!(current_digest);
    }
    artifacts
}

#[test]
fn observation_expectations_reject_tamper_and_preserve_every_non_catalog_byte() {
    let fixture = fixtures("agent-human-action");
    for (index, (id, _, _, _)) in OBSERVE_PAYLOADS.iter().enumerate() {
        let frozen = std::fs::read(
            fixture
                .join("artifacts/job-d166d1a72b51eb3b14528dae5cac37ee")
                .join(id),
        )
        .unwrap();
        let current = current_observe_payload(index, &frozen).unwrap();
        let restored = String::from_utf8(current.clone())
            .unwrap()
            .replace(catalog_lineage::CURRENT, catalog_lineage::OLD)
            .into_bytes();
        assert_eq!(restored, frozen);
        assert!(current_observe_payload(index, &current).is_err());
        let mut tampered = frozen.clone();
        tampered[0] ^= 1;
        assert!(current_observe_payload(index, &tampered).is_err());
        assert!(current_observe_payload(index, &frozen[..frozen.len() - 1]).is_err());
        assert!(current_observe_payload((index + 1) % OBSERVE_PAYLOADS.len(), &frozen).is_err());
    }
}

/// A development root holding the oracle's adopted Target, and the fake's
/// own root, below `scratch`.
pub(crate) fn roots(scratch: &Path, fixture: &Path) -> (PathBuf, PathBuf) {
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
pub(crate) fn calls(root: &Path) -> Vec<String> {
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
pub(crate) fn assert_windows_status(features: &[&str], expected: &str) {
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

/// `agent resume --resume-reference` end to end, as the Swift human-action
/// oracle's `connect` scenario (`agent-human-action`) records it: an agent
/// execution of `observe.device@1` with no adopted Target and the device
/// offline pauses for a person to connect it (`physicalConnection`,
/// `device.notObserved`), its action listed by `human-action list`, with
/// only device-list reads sent; with the device connected and the board
/// present (the daemon restarted over the same root), the resume by the
/// action's reference adopts the device, runs the Job and completes it. The
/// Job and its three Artifacts are the oracle's own (their references,
/// digests and sizes), and a second resume answers the same Job.
#[test]
fn agent_resume_completes_a_paused_execution_over_the_signed_test_daemon() {
    let _turn = crate::turn();
    let scratch = temporary("gj1-agent-resume");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let fixture = fixtures("agent-human-action");
    let cases: Value =
        serde_json::from_slice(&std::fs::read(fixture.join("cases.json")).unwrap()).unwrap();
    let completed = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == "connect.completed")
        .unwrap()["answer"]["result"]
        .clone();
    // No Target is adopted yet; the device is offline.
    let (root, fake_root) = (scratch.join("state"), scratch.join("fake"));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&fake_root).unwrap();
    std::fs::write(
        fake_root.join("hdc-mode"),
        "offline
",
    )
    .unwrap();
    let daemon = SignedDaemon::start(&executable, &pin, &root, &fixture, &fake_root);
    let (status, paused) = daemon.cli(&[
        "agent",
        "run",
        "--operation",
        "observe.device@1",
        "--execution-id",
        "har-connect",
    ]);
    assert_eq!(status, Some(75), "{paused}");
    let execution = &paused["error"]["details"]["execution"];
    assert_eq!(execution["state"], "waitingForHuman", "{paused}");
    let action = &execution["humanAction"];
    assert_eq!(action["category"], "physicalConnection", "{paused}");
    assert_eq!(action["reasonCode"], "device.notObserved", "{paused}");
    assert_eq!(action["minimumAction"], "human.connectOrPowerDevice");
    let reference = action["resumeReference"].as_str().unwrap().to_owned();
    let (status, listed) = daemon.cli(&["human-action", "list"]);
    assert_eq!(status, Some(0), "{listed}");
    assert_eq!(
        listed["result"]["items"][0]["resumeReference"],
        reference.as_str()
    );
    assert!(
        calls(&fake_root)
            .iter()
            .all(|call| call == "list targets -v"),
        "only the device list was read while it waited"
    );
    daemon.stop();

    // The device connected and the board present.
    std::fs::write(
        fake_root.join("hdc-mode"),
        "normal
",
    )
    .unwrap();
    let daemon =
        SignedDaemon::start_with_board(&executable, &pin, &root, &fixture, &fake_root, KEY);
    let (status, resumed) = daemon.cli(&["agent", "resume", "--resume-reference", &reference]);
    assert_eq!(status, Some(0), "{resumed}");
    assert_eq!(resumed["command"], "agent.resume", "{resumed}");
    let result = &resumed["result"];
    assert_eq!(result["executionId"], "har-connect", "{resumed}");
    assert_eq!(result["targetId"], TARGET, "{resumed}");
    assert_eq!(result["bindingRevision"], 1, "{resumed}");
    assert_eq!(
        result["jobId"], cases["jobs"]["connect"],
        "the oracle's Job"
    );
    assert_eq!(
        result["artifacts"],
        current_observe_artifacts(&fixture, &completed),
        "whole verified Artifacts, with only the independently proved Catalog field changed"
    );
    let (status, state) = daemon.cli(&["agent", "status", "--execution-id", "har-connect"]);
    assert_eq!(status, Some(0), "{state}");
    assert_eq!(state["result"]["state"], "completed", "{state}");
    assert_eq!(state["result"]["jobState"], "succeeded", "{state}");
    // Resumed again: the same completed execution, nothing run again.
    let before = calls(&fake_root).len();
    let (status, again) = daemon.cli(&["agent", "resume", "--resume-reference", &reference]);
    assert_eq!(status, Some(0), "{again}");
    assert_eq!(again["result"]["jobId"], result["jobId"], "{again}");
    assert_eq!(calls(&fake_root).len(), before, "nothing is sent again");
    daemon.stop();
    let _ = std::fs::remove_dir_all(&scratch);
    // Measured, but not counted: a resume submits the execution's operation
    // (the shared generic leaves' ruling of 2026-10-04).
    assert_windows_status(&["agent.resume"], "partial");
}

/// GJ-1's human-action loop through the real CLI, as the Swift human-action
/// oracle's `trust` and `connect` scenarios record it
/// (`agent-human-action`). An execution paused on the device's trust prompt
/// (`deviceTrustPrompt`) is abandoned: `agent abandon` under a stale
/// generation is refused (`resourceConflict`) and under the current one
/// accepted, after which its action reads expired and both `agent resume`
/// and `human-action resume` of it are refused (`humanActionExpired`) with
/// nothing dispatched. An execution paused for the device to be connected
/// (`physicalConnection`) is resumed and completed once the device is
/// connected and the board present; `human-action resume` of its action and
/// reference then answers that completed execution, the oracle's own Job, as
/// Swift's did, and a selection is refused there.
#[test]
fn the_human_action_loop_runs_over_the_signed_test_daemon() {
    let _turn = crate::turn();
    let scratch = temporary("gj1-human-action-loop");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let fixture = fixtures("agent-human-action");
    let cases: Value =
        serde_json::from_slice(&std::fs::read(fixture.join("cases.json")).unwrap()).unwrap();
    let (root, fake_root) = (scratch.join("state"), scratch.join("fake"));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&fake_root).unwrap();
    let mode =
        |mode: &str| std::fs::write(fake_root.join("hdc-mode"), format!("{mode}\n")).unwrap();
    let paused_action = |envelope: &Value| -> (String, String, String) {
        let execution = &envelope["error"]["details"]["execution"];
        assert_eq!(execution["state"], "waitingForHuman", "{envelope}");
        let action = &execution["humanAction"];
        (
            action["actionId"].as_str().unwrap().to_owned(),
            action["resumeReference"].as_str().unwrap().to_owned(),
            execution["generation"].as_str().unwrap().to_owned(),
        )
    };
    let refusal = |envelope: &Value, code: &str| {
        assert_eq!(envelope["ok"], false, "{envelope}");
        assert_eq!(envelope["error"]["code"], code, "{envelope}");
        assert_eq!(
            envelope["error"]["details"]["newDispatchCount"], 0,
            "{envelope}"
        );
    };

    // Paused for the device to be connected: no board, the device offline.
    mode("offline");
    let daemon = SignedDaemon::start(&executable, &pin, &root, &fixture, &fake_root);
    let (status, paused) = daemon.cli(&[
        "agent",
        "run",
        "--operation",
        "observe.device@1",
        "--execution-id",
        "har-connect",
    ]);
    assert_eq!(status, Some(75), "{paused}");
    let (connect_action, connect_reference, _) = paused_action(&paused);
    daemon.stop();

    // The board present, the device asking for trust.
    mode("unauthorized");
    let daemon =
        SignedDaemon::start_with_board(&executable, &pin, &root, &fixture, &fake_root, KEY);
    let (status, paused) = daemon.cli(&[
        "agent",
        "run",
        "--operation",
        "observe.device@1",
        "--execution-id",
        "har-trust",
    ]);
    assert_eq!(status, Some(75), "{paused}");
    assert_eq!(
        paused["error"]["details"]["execution"]["humanAction"]["category"], "deviceTrustPrompt",
        "{paused}"
    );
    let (trust_action, trust_reference, generation) = paused_action(&paused);
    let stale = (generation.parse::<u64>().unwrap() - 2).to_string();
    let (status, conflict) = daemon.cli(&[
        "agent",
        "abandon",
        "--execution-id",
        "har-trust",
        "--expected-generation",
        &stale,
    ]);
    assert_ne!(status, Some(0), "{conflict}");
    refusal(&conflict, "resourceConflict");
    let before = calls(&fake_root).len();
    let (status, abandoned) = daemon.cli(&[
        "agent",
        "abandon",
        "--execution-id",
        "har-trust",
        "--expected-generation",
        &generation,
    ]);
    assert_eq!(status, Some(0), "{abandoned}");
    assert_eq!(abandoned["command"], "agent.abandon", "{abandoned}");
    assert_eq!(
        abandoned["result"]["executionId"], "har-trust",
        "{abandoned}"
    );
    let (status, shown) = daemon.cli(&["human-action", "show", "--human-action", &trust_action]);
    assert_eq!(status, Some(0), "{shown}");
    let expired = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == "trust.expired")
        .unwrap()["answer"]["result"]["status"]
        .clone();
    assert_eq!(shown["result"]["status"], expired, "{shown}");
    let (_, resumed) = daemon.cli(&["agent", "resume", "--resume-reference", &trust_reference]);
    refusal(&resumed, "humanActionExpired");
    let (_, resumed) = daemon.cli(&[
        "human-action",
        "resume",
        "--human-action",
        &trust_action,
        "--resume-reference",
        &trust_reference,
    ]);
    refusal(&resumed, "humanActionExpired");
    assert_eq!(calls(&fake_root).len(), before, "nothing was dispatched");

    // The device connected: the connect execution resumed and completed
    // (`connect.resume`), then its action resumed again by `human-action
    // resume`, which answers the same completed execution
    // (`connect.againByAction`) and sends nothing.
    mode("normal");
    let (status, resumed) =
        daemon.cli(&["agent", "resume", "--resume-reference", &connect_reference]);
    assert_eq!(status, Some(0), "{resumed}");
    let (status, state) = daemon.cli(&["agent", "status", "--execution-id", "har-connect"]);
    assert_eq!(status, Some(0), "{state}");
    assert_eq!(state["result"]["state"], "completed", "{state}");
    let before = calls(&fake_root).len();
    let (status, by_action) = daemon.cli(&[
        "human-action",
        "resume",
        "--human-action",
        &connect_action,
        "--resume-reference",
        &connect_reference,
    ]);
    assert_eq!(status, Some(0), "{by_action}");
    assert_eq!(by_action["command"], "human-action.resume", "{by_action}");
    let recorded = &cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == "connect.againByAction")
        .unwrap()["answer"]["result"];
    for key in [
        "executionId",
        "state",
        "jobId",
        "jobState",
        "targetId",
        "bindingRevision",
    ] {
        assert_eq!(
            by_action["result"][key], recorded[key],
            "{key}: {by_action}"
        );
    }
    assert_eq!(calls(&fake_root).len(), before, "nothing was sent again");
    let (_, selected) = daemon.cli(&[
        "human-action",
        "resume",
        "--human-action",
        &connect_action,
        "--resume-reference",
        &connect_reference,
        "--selection",
        "any",
    ]);
    refusal(&selected, "invalidInput");
    daemon.stop();
    let _ = std::fs::remove_dir_all(&scratch);
    assert_windows_status(&["agent.abandon"], "implemented");
    // Measured, but not counted: like `agent resume`, a resolved action's
    // resume submits the execution's operation (the ruling of 2026-10-04).
    assert_windows_status(&["human-action.resume"], "partial");
}
