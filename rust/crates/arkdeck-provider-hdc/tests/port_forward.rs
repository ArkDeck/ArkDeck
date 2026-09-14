//! Swift's port-rule oracle (`rust/tests/fixtures/port-forward`, recorded by
//! `PortForwardOracleContractTests` over the shared fake HDC driver) replayed
//! by `PortAction`: the eight Jobs driven step by step as Swift's engine
//! drove them — a forward and a reverse rule each created, read back,
//! removed and read back absent; a create the device refuses; a removal of
//! a rule it never had; a rule it reports created but never lists, read
//! back absent and so removed again by the engine's compensation and read
//! back once more; a rule whose readback it cannot answer — every verdict
//! and every readback conclusion checked, and every argv the driver logged
//! compared with the oracle's 40 recorded lines.
#![cfg(target_os = "macos")]

mod common;

use arkdeck_provider_hdc::{
    Action, Expected, FilePlan, HdcDispatch, Outcome, PortAction, Property, Reconcile,
};
use common::{CONNECT_KEY, SharedFake};
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

fn oracle() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/port-forward")
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

/// The evidence preflight the engine runs before every port rule: the
/// device probe, the model and the firmware.
fn preflight(fake: &SharedFake) {
    for (action, step) in [
        (Action::ObserveDevice, "confirm-evidence-target"),
        (
            Action::QueryProperty(Property::ProductName),
            "read-evidence-model",
        ),
        (
            Action::QueryProperty(Property::FullBuildVersion),
            "read-evidence-firmware",
        ),
    ] {
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

fn dispatch(fake: &SharedFake, action: &PortAction, step: &str) -> Outcome {
    let FilePlan::Process(process) = action.lower(step, Some(CONNECT_KEY)).unwrap() else {
        panic!("{step}: one process")
    };
    action.verify(&fake.dispatch.dispatch(&process).unwrap())
}

fn present(outcome: &Outcome) -> Option<bool> {
    match outcome {
        Outcome::Verified(summary) => summary.get("present").map(|value| value == "true"),
        _ => None,
    }
}

/// What the engine does with the readback of a create or remove
/// (`verify-port-rule`): a presence other than the expected one is
/// `portForwardReadbackMismatch`, which compensates a create by removing the
/// rule and reading it back once more.
fn expected_presence(operation: &str) -> bool {
    operation == "port-forward.create@1"
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
    assert_eq!(log.len(), 40, "the oracle's eight Jobs");
    let fake = SharedFake::with_answers(&answers, None);
    let mut cursor = 0;
    for (name, mode) in [
        ("createForward", "normal"),
        ("removeForward", "normal"),
        ("createReverse", "normal"),
        ("removeReverse", "normal"),
        ("createRefused", "createRefused"),
        ("removeMissing", "normal"),
        ("ruleUnlisted", "ruleUnlisted"),
        ("readbackUnanswered", "readbackUnanswered"),
    ] {
        fake.set_mode(mode);
        fake.clear_invocations();
        let case = &cases["cases"][name];
        let operation = format!("{}@1", case["operation"].as_str().unwrap());
        let inputs: &Map<String, Value> = case["inputs"].as_object().unwrap();
        let (kind, step) = if expected_presence(&operation) {
            ("createPortForward", "create-port-rule")
        } else {
            ("removePortForward", "remove-port-rule")
        };
        preflight(&fake);
        let action = PortAction::for_step(kind, &operation, inputs)
            .unwrap()
            .unwrap();
        assert_eq!(action.effect(), "deviceMutation");
        let local_port = inputs["localPort"].as_i64().unwrap().to_string();
        let outcome = dispatch(&fake, &action, step);
        match name {
            "createRefused" | "removeMissing" => {
                assert_eq!(
                    outcome,
                    Outcome::Failed {
                        code: "portForwardFailed",
                        detail: format!("tcp:{local_port}"),
                    },
                    "{name}"
                );
                // The engine reads nothing back after a failed mutation and,
                // with nothing read back, the intent stays unknown.
                assert_eq!(
                    action.reconcile_without_readback(),
                    Reconcile::StillUnknown(
                        "device mutation needs a readback pass before it can be concluded".into()
                    )
                );
            }
            _ => {
                assert_eq!(
                    outcome,
                    Outcome::Verified(BTreeMap::from([("localPort".to_owned(), local_port)])),
                    "{name}"
                );
                let readback = PortAction::for_step("verifyRemoteState", &operation, inputs)
                    .unwrap()
                    .unwrap();
                assert_eq!(Some(readback.clone()), action.readback());
                assert_eq!(readback.effect(), "readOnly");
                let read = dispatch(&fake, &readback, "verify-port-rule");
                let conclusion = action.conclude(read.clone());
                match name {
                    "readbackUnanswered" => {
                        assert_eq!(
                            read,
                            Outcome::Unknown(
                                "port-forward presence readback is not trustworthy".into()
                            )
                        );
                        assert_eq!(
                            conclusion,
                            Reconcile::StillUnknown(
                                "port-forward presence readback is not trustworthy".into()
                            )
                        );
                    }
                    "ruleUnlisted" => {
                        assert_eq!(present(&read), Some(false), "the device never lists it");
                        assert_eq!(conclusion, Reconcile::ConfirmedNotExecuted);
                        // The engine's compensation: the inverse operation's
                        // mutation, then its own readback, which must find
                        // the rule absent.
                        let compensation = PortAction::Remove(action.rule().clone());
                        assert!(matches!(
                            dispatch(&fake, &compensation, "compensate-port-rule"),
                            Outcome::Verified(_)
                        ));
                        let restored = dispatch(
                            &fake,
                            &compensation.readback().unwrap(),
                            "verify-port-rule-compensation",
                        );
                        assert_eq!(present(&restored), Some(false));
                        assert_eq!(
                            compensation.conclude(restored),
                            Reconcile::ConfirmedCompleted(BTreeMap::from([(
                                "postconditionPresent".to_owned(),
                                "false".to_owned()
                            )]))
                        );
                    }
                    _ => {
                        let expected = expected_presence(&operation);
                        assert_eq!(present(&read), Some(expected), "{name}");
                        assert_eq!(
                            conclusion,
                            Reconcile::ConfirmedCompleted(BTreeMap::from([(
                                "postconditionPresent".to_owned(),
                                expected.to_string()
                            )])),
                            "{name}"
                        );
                    }
                }
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
}
