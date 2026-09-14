//! Swift's pointer-gesture oracle (`rust/tests/fixtures/pointer-input`,
//! recorded by `PointerInputOracleContractTests` over the shared fake HDC
//! driver) replayed by `PointerAction`: the five Jobs driven step by step as
//! Swift's engine drove them — the tap, the long press on display 2 and the
//! swipe the injector acknowledges, the tap it rejects, the tap it answers
//! with another gesture's acknowledgement — every verdict checked and every
//! argv the driver logged compared with the oracle's 12 recorded lines; and
//! the two gestures the typed plan refuses before anything is sent, refused
//! here with the same words the oracle's plan refusals carry.
#![cfg(target_os = "macos")]

mod common;

use arkdeck_provider_hdc::{
    Action, Expected, FilePlan, HdcDispatch, Outcome, PointerAction, Property, Reconcile,
};
use common::{CONNECT_KEY, SharedFake};
use serde_json::{Map, Value};
use std::fs;
use std::path::{Path, PathBuf};

/// The harness's fixed clock, the provider's `nowUTC` at dispatch.
const NOW: &str = "2026-09-14T00:00:00Z";

fn oracle() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/pointer-input")
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn logged(fake: &SharedFake) -> Vec<String> {
    String::from_utf8(fake.invocations())
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect()
}

/// The evidence preflight the engine runs before the gesture: the device
/// probe every Job, the model and firmware reads only for the first Job of
/// the oracle (the later Jobs carry them from the session).
fn preflight(fake: &SharedFake, reads: bool) {
    let mut steps = vec![(Action::ObserveDevice, "confirm-evidence-target")];
    if reads {
        steps.push((
            Action::QueryProperty(Property::ProductName),
            "read-evidence-model",
        ));
        steps.push((
            Action::QueryProperty(Property::FullBuildVersion),
            "read-evidence-firmware",
        ));
    }
    for (action, step) in steps {
        let plan = action.lower(step, Some(CONNECT_KEY)).unwrap();
        let receipt = fake.dispatch.dispatch(&plan).unwrap();
        assert!(
            matches!(
                action.verify(
                    &receipt,
                    Expected {
                        connect_key: Some(CONNECT_KEY),
                        ..Expected::default()
                    }
                ),
                Outcome::Verified(_)
            ),
            "{step} verifies over the oracle's fake"
        );
    }
}

fn case<'a>(cases: &'a Value, name: &str) -> (String, &'a Map<String, Value>) {
    let case = &cases["cases"][name];
    (
        format!("{}@1", case["operation"].as_str().unwrap()),
        case["inputs"].as_object().unwrap(),
    )
}

fn plan_refusal(cases: &Value, name: &str) -> String {
    cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == format!("{name}.plan"))
        .map(|exchange| {
            exchange["answer"]["error"]["message"]
                .as_str()
                .unwrap()
                .to_owned()
        })
        .unwrap()
}

#[test]
fn every_oracle_job_replays_argv_for_argv_over_the_shared_fake() {
    let oracle = oracle();
    let cases = read_json(&oracle.join("cases.json"));
    let answers = fs::read_to_string(oracle.join("hdc-answers.sh")).unwrap();
    let log: Vec<String> = fs::read_to_string(oracle.join("hdc-invocations.log"))
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    assert_eq!(log.len(), 12, "the oracle's five Jobs");
    let fake = SharedFake::with_answers(&answers, None);
    let mut cursor = 0;
    for (index, (name, mode)) in [
        ("tap", "normal"),
        ("longPress", "normal"),
        ("swipe", "normal"),
        ("rejected", "rejected"),
        ("otherGesture", "otherGesture"),
    ]
    .into_iter()
    .enumerate()
    {
        fake.set_mode(mode);
        fake.clear_invocations();
        preflight(&fake, index == 0);
        let (operation, inputs) = case(&cases, name);
        let action = PointerAction::for_step("injectPointerInput", &operation, inputs, NOW)
            .unwrap()
            .unwrap();
        assert_eq!(action.effect(), "deviceMutation");
        let FilePlan::Process(process) = action
            .lower("inject-pointer-input", Some(CONNECT_KEY))
            .unwrap()
        else {
            panic!("{name}: one process")
        };
        let receipt = fake.dispatch.dispatch(&process).unwrap();
        let outcome = action.verify(&receipt);
        match name {
            "tap" | "longPress" | "swipe" => {
                let Outcome::Verified(summary) = &outcome else {
                    panic!("{name}: {outcome:?}")
                };
                assert_eq!(summary["frame"], "1280x2832");
                match name {
                    "tap" => {
                        assert_eq!(summary["gesture"], "tap");
                        assert_eq!(
                            (summary["x"].as_str(), summary["y"].as_str()),
                            ("640", "1500")
                        );
                        assert!(!summary.contains_key("loweredHoldMs"));
                    }
                    "longPress" => {
                        assert_eq!(summary["gesture"], "longPress");
                        assert_eq!(summary["loweredHoldMs"], "1200");
                        assert_eq!(summary["durationMs"], "1200");
                        assert_eq!(summary["displayId"], "2");
                    }
                    _ => {
                        assert_eq!(summary["gesture"], "swipe");
                        assert_eq!(
                            (summary["toX"].as_str(), summary["toY"].as_str()),
                            ("100", "1200")
                        );
                        assert_eq!(summary["loweredHoldMs"], "500");
                    }
                }
            }
            "rejected" => assert_eq!(
                outcome,
                Outcome::Failed {
                    code: "pointerInputRejected",
                    detail: "parameter error, unable to run".into(),
                }
            ),
            _ => {
                assert_eq!(
                    outcome,
                    Outcome::Unknown(
                        "uinput did not acknowledge the tap it was given; the gesture may or may \
                         not have been injected"
                            .into()
                    )
                );
                assert_eq!(action.readback(), None);
                assert_eq!(
                    action.reconcile(),
                    Reconcile::StillUnknown(
                        "an injected pointer gesture has no observable readback".into()
                    )
                );
            }
        }
        let lines = logged(&fake);
        let expected = &log[cursor..cursor + lines.len()];
        assert_eq!(
            lines, expected,
            "{name}: the argv the driver logged is the oracle's"
        );
        cursor += lines.len();
    }
    assert_eq!(cursor, log.len(), "every recorded line was replayed");
    // The gestures the typed plan refuses before authorization: the oracle
    // recorded the engine's refusal at `job.plan`; the provider's refusal
    // here is the same text under Swift's prefix.
    for name in ["expired", "outOfFrame"] {
        let (operation, inputs) = case(&cases, name);
        let refused = PointerAction::for_step("injectPointerInput", &operation, inputs, NOW)
            .unwrap_err()
            .to_string();
        let inner = refused
            .strip_prefix("unsupportedAction(\"")
            .and_then(|text| text.strip_suffix("\")"))
            .unwrap_or(&refused);
        assert_eq!(
            plan_refusal(&cases, name),
            format!("typed plan preflight failed before authorization: {inner}"),
            "{name}"
        );
    }
}
