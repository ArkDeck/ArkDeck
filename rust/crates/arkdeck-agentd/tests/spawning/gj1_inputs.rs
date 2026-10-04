//! GJ-1's pointer inputs end to end on Windows (TASK-XPA-005): the real
//! signed `arkdeck.exe` sends `input tap`, `input long-press` and `input
//! swipe` (`input.tap@1`, `input.long-press@1`, `input.swipe@1`) to the
//! signed test daemon (`signed_daemon.rs`), which composes the production
//! Windows development root with the shared fake HDC's answers in process
//! (`oracle_fake.rs`), a synthetic USB census naming the fixture's board, the
//! oracle's fixed clock, and its own Job state for the device mutations'
//! continuity (`MUTATION_ROOT`).
//!
//! Every case the Swift pointer-input oracle recorded
//! (`rust/tests/fixtures/pointer-input`) is sent in the oracle's order, with
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
            .cloned()
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
                assert_eq!(sent, jobs.next().unwrap(), "{name}: the oracle's Job calls");
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
                assert_eq!(
                    refusal(&envelope),
                    (
                        recorded["error"]["code"].clone(),
                        recorded["error"]["message"].clone()
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
    assert_eq!(
        listed["result"],
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
