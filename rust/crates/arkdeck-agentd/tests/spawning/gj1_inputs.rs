//! GJ-1's pointer inputs, screen record and port forwards end to end on
//! Windows (TASK-XPA-005): the real signed `arkdeck.exe` sends `input tap`,
//! `input long-press` and `input swipe` (`input.tap@1`, `input.long-press@1`,
//! `input.swipe@1`), `screen record` (`capture.screen-sequence@1`) and
//! `port-forward create|remove` (`port-forward.create@1`,
//! `port-forward.remove@1`), and `input keyboard` (`input.keyboard@1`) to
//! the signed test daemon (`signed_daemon.rs`), which composes the production
//! Windows development root with the shared fake HDC's answers in process
//! (`oracle_fake.rs`), a synthetic USB census naming the fixture's board, the
//! oracle's fixed clock, and its own Job state for the device mutations'
//! continuity (`MUTATION_ROOT`).
//!
//! Every case each Swift oracle recorded (`rust/tests/fixtures/pointer-input`,
//! `screen-sequence`, `port-forward`) is sent in the oracle's order, with
//! the fake in the case's mode: a Job the oracle ran ends in the oracle's
//! state, with the oracle's step kinds, after exactly the oracle's calls of
//! that Job (the device list reads aside, which the CLI's own observation
//! adds); a request the oracle's Runtime refused is refused with the same
//! code and words, and sends nothing. The Runtime capabilities the run
//! leaves are then the oracle's, an unknown outcome blocking its lineage.
//! Host tests only: no device, `hdc` or board is reached.
use crate::gj1_device_leaves::{KEY, TARGET, assert_windows_status, calls, roots};
use crate::signed_daemon::{self, SignedDaemon, fixtures, signed_copy, temporary};
use serde_json::Value;
use std::path::Path;

/// The JSON document `name` of `fixture`.
fn document(fixture: &Path, name: &str) -> Value {
    serde_json::from_slice(&std::fs::read(fixture.join(name)).unwrap()).unwrap()
}

/// The recorded exchange `name`, if the oracle sent it.
fn exchange<'a>(cases: &'a Value, name: &str) -> Option<&'a Value> {
    cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == name)
}

/// The cases in the order the oracle planned them.
fn order(cases: &Value) -> Vec<String> {
    cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|exchange| exchange["name"].as_str()?.strip_suffix(".plan"))
        .map(str::to_owned)
        .collect()
}

/// The calls of each Job the oracle ran, in order, without the device list
/// reads that open each.
fn oracle_jobs(fixture: &Path) -> Vec<Vec<String>> {
    let mut jobs: Vec<Vec<String>> = Vec::new();
    for call in calls(fixture) {
        if call == "list targets -v" {
            jobs.push(Vec::new());
        } else {
            jobs.last_mut()
                .expect("a Job opens with its device list")
                .push(call);
        }
    }
    jobs
}

/// `call` with a receive's host path spelled by its file name alone: the
/// oracle's is below its macOS root, this run's below the daemon's.
fn received_as_named(call: &str) -> String {
    match call.split_once(" file recv ") {
        Some((head, rest)) => {
            let (device, host) = rest.rsplit_once(' ').unwrap_or((rest, ""));
            let name = host.rsplit(['/', '\\']).next().unwrap_or_default();
            format!("{head} file recv {device} {name}")
        }
        None => call.to_owned(),
    }
}

/// The Runtime's answer behind a refused leaf's envelope: its wire code and
/// words.
fn refusal(envelope: &Value) -> (Value, Value) {
    assert_eq!(envelope["ok"], false, "{envelope}");
    let error = &envelope["error"];
    let code = error["details"]
        .get("wireCode")
        .unwrap_or(&error["code"])
        .clone();
    (code, error["message"].clone())
}

/// Replays every case of the oracle in `fixture` through the leaf
/// `leaf(operation)` names, with the daemon over `scratch`, and returns the
/// daemon (still serving) and the fake's root.
fn replay(
    scratch: &Path,
    executable: &Path,
    pin: &str,
    fixture: &Path,
    leaf: &dyn Fn(&str) -> Vec<&'static str>,
) -> (SignedDaemon, std::path::PathBuf) {
    let cases = document(fixture, "cases.json");
    let provenance = document(fixture, "provenance.json");
    let (root, fake_root) = roots(scratch, fixture);
    let clock = format!(
        "{}|{}",
        provenance["nowUTC"].as_str().unwrap(),
        provenance["nowPreciseUTC"].as_str().unwrap()
    );
    let daemon = SignedDaemon::start_with(
        executable,
        pin,
        &root,
        fixture,
        &fake_root,
        &[
            (signed_daemon::BOARD, KEY.to_owned()),
            (signed_daemon::CLOCK, clock),
            (
                signed_daemon::MUTATION_ROOT,
                root.join("jobs-state").to_str().unwrap().to_owned(),
            ),
        ],
    );
    let mut jobs = oracle_jobs(fixture).into_iter();
    // Each Runtime capability this run consumed, named as the oracle's. A
    // gesture's capability is session-scoped and named by its frame alone,
    // so it is the oracle's; another's name covers its plan digest, which
    // covers a receive's host path, spelled otherwise on Windows, so it is
    // relabelled one to one (as the GJ-2/3 replays relabel, rulings 48 and
    // 61).
    let mut labels: Vec<(String, String)> = Vec::new();
    let relabelled = |text: &str, labels: &[(String, String)]| {
        labels.iter().fold(text.to_owned(), |text, (host, swift)| {
            text.replace(host, swift)
        })
    };
    let inputs = scratch.join("inputs.json");
    for name in order(&cases) {
        let case = &cases["cases"][&name];
        // The operation the oracle's request named.
        let request: Value = serde_json::from_str(
            exchange(&cases, &format!("{name}.plan")).unwrap()["params"]["requestJson"]
                .as_str()
                .unwrap(),
        )
        .unwrap();
        let operation = request["operation"]["id"].as_str().unwrap().to_owned();
        let mode = case["mode"].as_str().unwrap_or("normal");
        std::fs::write(fake_root.join("hdc-mode"), format!("{mode}\n")).unwrap();
        std::fs::write(&inputs, serde_json::to_vec(&case["inputs"]).unwrap()).unwrap();
        let before = calls(&fake_root).len();
        let mut arguments = leaf(&operation);
        arguments.extend([
            "--target",
            TARGET,
            "--inputs-file",
            inputs.to_str().unwrap(),
        ]);
        let (status, envelope) = daemon.cli(&arguments);
        let sent: Vec<String> = calls(&fake_root)[before..]
            .iter()
            .filter(|call| *call != "list targets -v")
            .map(|call| received_as_named(call))
            .collect();
        match case["ends"].as_str() {
            // A Job the oracle ran: its end, its steps and its calls.
            Some(ends) => {
                let expected = if ends == "succeeded" { 0 } else { 1 };
                assert_eq!(status, Some(expected), "{name}: {envelope}");
                assert_eq!(envelope["ok"], true, "{name}: {envelope}");
                let receipt = &envelope["result"];
                // The receipt names an unknown outcome as such; the Job
                // itself waits for its typed reconcile, as the oracle's did.
                let terminal = if ends == "waitingForRecovery" {
                    "outcomeUnknown"
                } else {
                    ends
                };
                assert_eq!(receipt["terminalState"], terminal, "{name}: {receipt}");
                let job = receipt["jobID"].as_str().unwrap();
                let (status, state) = daemon.cli(&["job", "status", "--job", job]);
                assert_eq!(status, Some(0), "{name}: {state}");
                assert_eq!(state["result"]["state"], ends, "{name}: {state}");
                let reference = format!("{}@1", operation);
                assert_eq!(receipt["operationReference"], reference.as_str());
                let evidence = &exchange(&cases, &format!("{name}.evidence")).unwrap()["answer"];
                assert_eq!(
                    receipt["stepKinds"], evidence["result"]["actualStepKinds"],
                    "{name}: {receipt}"
                );
                assert_eq!(
                    receipt["outcomeUnknown"],
                    ends == "waitingForRecovery",
                    "{name}: {receipt}"
                );
                if let (Some(host), Some(swift)) = (
                    receipt["authority"]["reference"].as_str(),
                    evidence["result"]["authority"]["reference"].as_str(),
                ) {
                    match labels.iter().find(|(known, _)| known == host) {
                        Some((_, known)) => assert_eq!(known, swift, "{name}"),
                        None => {
                            assert!(
                                labels.iter().all(|(_, known)| known != swift),
                                "{name}: {swift} is named twice"
                            );
                            labels.push((host.to_owned(), swift.to_owned()));
                        }
                    }
                }
                // The oracle's calls, its Job's name in them this run's.
                let oracle_job = cases["jobs"][&name].as_str().unwrap();
                let expected: Vec<String> = jobs
                    .next()
                    .unwrap()
                    .iter()
                    .map(|call| received_as_named(&call.replace(oracle_job, job)))
                    .collect();
                assert_eq!(sent, expected, "{name}: the oracle's Job calls");
                // Its Artifacts, as many as the oracle's.
                if let Some(listed) = exchange(&cases, &format!("{name}.artifacts")) {
                    assert_eq!(
                        receipt["artifacts"].as_array().unwrap().len(),
                        listed["answer"]["result"]["items"]
                            .as_array()
                            .unwrap()
                            .len(),
                        "{name}: {receipt}"
                    );
                }
            }
            // A request the oracle's Runtime refused: the same refusal,
            // nothing sent.
            None => {
                assert_ne!(status, Some(0), "{name}: {envelope}");
                let recorded = [".plan", ".submit"]
                    .iter()
                    .filter_map(|step| exchange(&cases, &format!("{name}{step}")))
                    .map(|exchange| &exchange["answer"])
                    .find(|answer| answer["ok"] == false)
                    .unwrap_or_else(|| panic!("{name}: the oracle refused nothing"));
                let (code, message) = refusal(&envelope);
                assert_eq!(
                    (code, relabelled(message.as_str().unwrap(), &labels)),
                    (
                        recorded["error"]["code"].clone(),
                        recorded["error"]["message"].as_str().unwrap().to_owned()
                    ),
                    "{name}"
                );
                assert_eq!(sent, Vec::<String>::new(), "{name}: nothing is sent");
            }
        }
    }
    assert!(jobs.next().is_none(), "every Job the oracle ran was run");
    // The standing capabilities the runs consumed: the oracle's.
    let (status, listed) = daemon.cli(&["capability", "list"]);
    assert_eq!(status, Some(0), "{listed}");
    let listed: Value =
        serde_json::from_str(&relabelled(&listed["result"].to_string(), &labels)).unwrap();
    assert_eq!(
        listed,
        exchange(&cases, "capabilities.list").unwrap()["answer"]["result"],
        "{listed}"
    );
    (daemon, fake_root)
}

#[test]
fn pointer_inputs_answer_as_the_swift_oracle_over_the_signed_test_daemon() {
    let _turn = crate::turn();
    let scratch = temporary("gj1-pointer-inputs");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let fixture = fixtures("pointer-input");
    let (daemon, _) = replay(
        &scratch,
        &executable,
        &pin,
        &fixture,
        &|operation| match operation {
            "input.tap" => vec!["input", "tap"],
            "input.long-press" => vec!["input", "long-press"],
            "input.swipe" => vec!["input", "swipe"],
            other => panic!("no pointer leaf for {other}"),
        },
    );
    daemon.stop();
    let _ = std::fs::remove_dir_all(&scratch);
    assert_windows_status(
        &["input.tap@1", "input.long-press@1", "input.swipe@1"],
        "implemented",
    );
}

/// `screen record` (`capture.screen-sequence@1`) over the Swift
/// screen-sequence oracle's fake: every case the oracle recorded, a captured,
/// a scaled and a gapped sequence, the low-storage, empty-archive and residue
/// failures, the missing archive's unknown outcome and the refusals after it,
/// each with the oracle's calls (its Job's owned paths named by this run's
/// Job) and as many Artifacts as the oracle's.
#[test]
fn screen_record_answers_as_the_swift_oracle_over_the_signed_test_daemon() {
    let _turn = crate::turn();
    let scratch = temporary("gj1-screen-record");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let fixture = fixtures("screen-sequence");
    let (daemon, _) = replay(
        &scratch,
        &executable,
        &pin,
        &fixture,
        &|operation| match operation {
            "capture.screen-sequence" => vec!["screen", "record"],
            other => panic!("no screen leaf for {other}"),
        },
    );
    daemon.stop();
    let _ = std::fs::remove_dir_all(&scratch);
    assert_windows_status(&["capture.screen-sequence@1"], "implemented");
}

/// `port-forward create` and `port-forward remove` over the Swift
/// port-forward oracle's fake: every case the oracle recorded, a forward and
/// a reverse rule created and removed, a refused create, a missing rule's
/// removal, a rule the readback does not list, the unanswered readback's
/// unknown outcome and the refusals after it, each with the oracle's calls;
/// the unlisted rule is removed again, and no rule is left on the fake
/// device but the one whose readback went unanswered.
#[test]
fn port_forwards_answer_as_the_swift_oracle_over_the_signed_test_daemon() {
    let _turn = crate::turn();
    let scratch = temporary("gj1-port-forwards");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let fixture = fixtures("port-forward");
    let (daemon, fake_root) =
        replay(
            &scratch,
            &executable,
            &pin,
            &fixture,
            &|operation| match operation {
                "port-forward.create" => vec!["port-forward", "create"],
                "port-forward.remove" => vec!["port-forward", "remove"],
                other => panic!("no port-forward leaf for {other}"),
            },
        );
    let mut left: Vec<String> = std::fs::read_dir(&fake_root)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with("device-rule-"))
        .collect();
    left.sort();
    assert_eq!(
        left,
        ["device-rule-tcp_23456_tcp_34566"],
        "the rules the device keeps"
    );
    daemon.stop();
    let _ = std::fs::remove_dir_all(&scratch);
    assert_windows_status(
        &["port-forward.create@1", "port-forward.remove@1"],
        "implemented",
    );
}

/// The private text the keyboard input sends, as the macOS Rust owner test's
/// (`arkdeck-hoststore/tests/keyboard_input_run.rs`).
const PRIVATE_TEXT: &str = "private-fixture-你好-$()-'";

/// Every file's bytes below `path`, if it exists.
fn every_file(path: &Path) -> Vec<Vec<u8>> {
    let mut bytes = Vec::new();
    for entry in std::fs::read_dir(path).into_iter().flatten() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            bytes.extend(every_file(&path));
        } else {
            bytes.push(std::fs::read(path).unwrap());
        }
    }
    bytes
}

/// `artifact import keyboard-input` and `input keyboard`
/// (`input.keyboard@1`), which no Swift oracle records, against the macOS
/// Rust owner test's answers (`keyboard_input_run.rs`): its synthetic
/// transport, ported into the shared fake (`Answers::KeyboardInput`), with a
/// fragment of its own written beside the replay root. For each of its
/// replies, over a fresh root: the private text is imported as a sensitive
/// Import, whose receipt never carries it; an intent older than ten seconds
/// is refused with nothing sent; the input then ends as the macOS test's does
/// (acknowledged: `succeeded`; refused: `failed`; unacknowledged or
/// unobserved: an unknown outcome, the Job `waitingForRecovery`, and the next
/// input refused, never replayed), the UiTest text action sent exactly once;
/// and no Job, capability or Session record holds the private text.
#[test]
fn keyboard_input_answers_as_the_macos_runtime_over_the_signed_test_daemon() {
    let _turn = crate::turn();
    let scratch = temporary("gj1-keyboard-input");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    // The answers' fragment and tool, and the oracles' adopted Target.
    let fixture = scratch.join("keyboard-input");
    std::fs::create_dir_all(fixture.join("targets-state")).unwrap();
    std::fs::write(
        fixture.join("hdc-answers.sh"),
        "# input.keyboard@1 answers of keyboard_input_run.rs's synthetic transport, by mode.\n",
    )
    .unwrap();
    std::fs::write(
        fixture.join("hdc"),
        b"keyboard_input_run.rs synthetic transport\n",
    )
    .unwrap();
    std::fs::copy(
        fixtures("pointer-input").join("targets-state/targets.json"),
        fixture.join("targets-state/targets.json"),
    )
    .unwrap();
    let payload = scratch.join("keyboard-input.json");
    std::fs::write(
        &payload,
        serde_json::to_vec(&serde_json::json!({
            "kind": "text",
            "text": PRIVATE_TEXT,
            "allowDeviceClipboard": true
        }))
        .unwrap(),
    )
    .unwrap();
    let inputs = scratch.join("inputs.json");
    let keyboard = |fake_root: &Path| {
        calls(fake_root)
            .iter()
            .filter(|call| call.contains(" shell uitest uiInput text "))
            .count()
    };
    for (mode, ends) in [
        ("normal", "succeeded"),
        ("refused", "failed"),
        ("missingAck", "waitingForRecovery"),
        ("unobservable", "waitingForRecovery"),
    ] {
        let run = scratch.join(mode);
        std::fs::create_dir_all(&run).unwrap();
        let (root, fake_root) = roots(&run, &fixture);
        std::fs::write(fake_root.join("hdc-mode"), format!("{mode}\n")).unwrap();
        let daemon = SignedDaemon::start_with(
            &executable,
            &pin,
            &root,
            &fixture,
            &fake_root,
            &[
                (signed_daemon::BOARD, KEY.to_owned()),
                (
                    signed_daemon::CLOCK,
                    "2026-09-14T00:00:00Z|2026-09-14T00:00:00.000Z".to_owned(),
                ),
                (
                    signed_daemon::MUTATION_ROOT,
                    root.join("jobs-state").to_str().unwrap().to_owned(),
                ),
            ],
        );
        let (status, imported) = daemon.cli(&[
            "artifact",
            "import",
            "keyboard-input",
            "--import-request-id",
            &format!("keyboard-{mode}"),
            "--target",
            TARGET,
            "--file",
            payload.to_str().unwrap(),
        ]);
        assert_eq!(status, Some(0), "{mode}: {imported}");
        let receipt = &imported["result"]["receipt"];
        assert_eq!(receipt["privacy"], "sensitive", "{mode}: {imported}");
        assert!(!imported.to_string().contains(PRIVATE_TEXT), "{mode}");
        let lease = receipt["lease"].clone();
        let send = |epoch: &str| {
            std::fs::write(
                &inputs,
                serde_json::to_vec(&serde_json::json!({
                    "keyboardArtifactLease": lease,
                    "inputEpochUtc": epoch
                }))
                .unwrap(),
            )
            .unwrap();
            daemon.cli(&[
                "input",
                "keyboard",
                "--target",
                TARGET,
                "--inputs-file",
                inputs.to_str().unwrap(),
            ])
        };
        // An intent older than ten seconds: refused, nothing sent.
        let (status, stale) = send("2026-09-13T23:59:40Z");
        assert_ne!(status, Some(0), "{mode}: {stale}");
        assert_eq!(stale["ok"], false, "{mode}: {stale}");
        assert_eq!(keyboard(&fake_root), 0, "{mode}: nothing is sent");
        // A current intent: the macOS test's end, sent once.
        let (status, sent) = send("2026-09-14T00:00:00Z");
        assert_eq!(
            status,
            Some(if ends == "succeeded" { 0 } else { 1 }),
            "{mode}: {sent}"
        );
        assert_eq!(sent["ok"], true, "{mode}: {sent}");
        let job = sent["result"]["jobID"].as_str().unwrap().to_owned();
        let (_, state) = daemon.cli(&["job", "status", "--job", &job]);
        assert_eq!(state["result"]["state"], ends, "{mode}: {state}");
        assert_eq!(
            sent["result"]["outcomeUnknown"],
            ends == "waitingForRecovery",
            "{mode}: {sent}"
        );
        assert_eq!(keyboard(&fake_root), 1, "{mode}: sent once");
        assert!(!sent.to_string().contains(PRIVATE_TEXT), "{mode}");
        if ends == "waitingForRecovery" {
            // The unknown use blocks the lineage: the next input is refused
            // and the first never replayed.
            let (status, after) = send("2026-09-14T00:00:00Z");
            assert_ne!(status, Some(0), "{mode}: {after}");
            let (code, _) = refusal(&after);
            assert_eq!(code, "admissionDenied", "{mode}: {after}");
            assert_eq!(keyboard(&fake_root), 1, "{mode}: never replayed");
        }
        daemon.stop();
        // The private bytes belong to the sensitive Import alone.
        for bytes in every_file(&root.join("jobs-state"))
            .into_iter()
            .chain(every_file(&root.join("sessions")))
        {
            assert!(
                !bytes
                    .windows(PRIVATE_TEXT.len())
                    .any(|slice| slice == PRIVATE_TEXT.as_bytes()),
                "{mode}: a Job or Session record holds the private text"
            );
        }
    }
    let _ = std::fs::remove_dir_all(&scratch);
    assert_windows_status(&["input.keyboard@1"], "implemented");
}
