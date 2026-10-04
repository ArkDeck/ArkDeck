//! `runtime.tool.select` answers the tool-selection action's one projection
//! (`RuntimeToolSelectionControlAction.projection`) in whatever state the
//! action holds. Swift's daemon returned it as it was — awaiting approval,
//! blocked, drifted or settled — and its CLI printed it. The published result
//! was derived from the recorded awaiting-approval answer alone, so a blocked
//! or drifted action became `internalError` (live c2 run of 2026-10-05,
//! finding 2). The Swift store oracle (`ToolSelectionStoreOracleContractTests`,
//! `rust/tests/fixtures/tool-selection-store/projections.json`) recorded the
//! projection in every state; the derivation now admits those.
//!
//! check-contracts' published view compiles this build against the merge
//! base's contract, which predates the widening: there only what does not
//! conform is reported, and nothing is asserted.
use arkdeck_contract::validate_method_value;
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::Path;

fn published_view() -> bool {
    let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}

fn repository(path: &str) -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .join(path)
}

#[test]
fn every_state_swift_projected_is_a_select_result() {
    let projections: Vec<Value> = serde_json::from_slice(
        &std::fs::read(repository(
            "rust/tests/fixtures/tool-selection-store/projections.json",
        ))
        .unwrap(),
    )
    .unwrap();
    let states: BTreeSet<&str> = projections
        .iter()
        .map(|projection| projection["state"].as_str().unwrap())
        .collect();
    for state in [
        "awaitingImpactApproval",
        "blocked",
        "previewDrifted",
        "failed",
    ] {
        assert!(
            states.contains(state),
            "the oracle records {state}: {states:?}"
        );
    }
    let refused: Vec<(&str, String)> = projections
        .iter()
        .filter_map(|projection| {
            validate_method_value("runtime.tool.select", "result", projection)
                .err()
                .map(|error| (projection["state"].as_str().unwrap(), format!("{error:?}")))
        })
        .collect();
    if published_view() {
        eprintln!("published view: {refused:?}");
        return;
    }
    assert!(refused.is_empty(), "{refused:?}");
}

/// The recorded frames still conform, and the widening admits only the
/// projection's own members: an unknown member stays refused.
#[test]
fn the_recorded_answer_conforms_and_the_result_stays_closed() {
    let frames: Vec<Value> = std::fs::read_to_string(repository(
        "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/runtime.tool.select.jsonl",
    ))
    .unwrap()
    .lines()
    .map(|line| serde_json::from_str(line).unwrap())
    .collect();
    let answer = frames
        .iter()
        .find(|frame| frame["ok"] == true)
        .map(|frame| frame["result"].clone())
        .unwrap();
    assert!(validate_method_value("runtime.tool.select", "result", &answer).is_ok());
    let mut widened = answer.clone();
    widened["unrecorded"] = Value::Bool(true);
    assert!(validate_method_value("runtime.tool.select", "result", &widened).is_err());
}
