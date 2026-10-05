//! The protected Flash recovery broker's `executePinnedRequest` through the
//! Host and Control (TASK-XPA-017, S2b): `debug.start` pins the oracle's
//! canonical full restore, and `debug.evaluate` executes it. The broker writes
//! the attempt's permit record and its `executing` evaluation, then the Host's
//! driver admits the attempt through the Flash admission and runs it through
//! the Flash runner, and the evaluation is settled by the Job's classified
//! outcome: completed, and an unknown outcome that is never replayed.
//!
//! The Host is `flash_execution_control`'s, with the invocation owner beside
//! the planner's state. Its only external ports are the Swift Flash run
//! oracle's fake lane and Rockchip host; nothing here is device evidence.
//!
//! On Windows (TASK-XPA-010) the Host is `flash_execution_control`'s Windows
//! one, its HDC the in-process fake given through the test seam.
use crate::flash_execution_control::{Root, execution_fakes, flash_host, request};
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION};
use arkdeck_control::Control;
use serde_json::{Value, json};
use std::process::Command;

const SOURCE: &str = "0000000000000000000000000000000000000000000000000000000000000001";
const BUILD: &str = "0000000000000000000000000000000000000000000000000000000000000065";
const EXECUTE: &str = r#"{"schemaVersion":"1.0.0","action":"executePinnedRequest"}"#;

fn run_case(outcome: &str) {
    let _turn = crate::turn();
    let root = crate::flash_execution_control::ChildRoot::new();
    let (key, path) = root.env();
    let output = Command::new(std::env::current_exe().unwrap())
        .env("ARKDECK_TEST_FLASH_BROKER_OUTCOME", outcome)
        .env(key, path)
        .args([
            "--exact",
            "flash_broker_control::flash_broker_process_fixture",
            "--ignored",
            "--nocapture",
        ])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn the_broker_executes_its_pinned_flash_to_completion() {
    run_case("completed");
}

#[test]
fn the_broker_settles_an_unknown_flash_outcome_without_replay() {
    run_case("unknown");
}

#[test]
#[ignore = "subprocess fixture: invoked by the flash broker cases"]
fn flash_broker_process_fixture() {
    let _turn = crate::turn();
    let unknown = std::env::var("ARKDECK_TEST_FLASH_BROKER_OUTCOME").as_deref() == Ok("unknown");
    let root = Root::new();
    let fakes = execution_fakes::Fakes::default();
    if unknown {
        fakes.begin(execution_fakes::Script {
            perform: "outcomeUnknown".into(),
            terminal: "outcomeUnknown".into(),
            ..Default::default()
        });
    }
    let state = root.0.join("jobs");
    let control = Control::new(
        flash_host(&root, &fakes)
            .with_flash_invocations(arkdeck_hoststore::FlashInvocations::open(&state).unwrap()),
    )
    .unwrap();
    let call = |method: &str, params: Value| -> Value {
        serde_json::from_slice(
            &control.handle_frame(
                &serde_json::to_vec(&json!({
                    "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
                    "id": "flash-broker-control", "method": method, "params": params,
                }))
                .unwrap(),
            ),
        )
        .unwrap()
    };
    let started = call(
        "debug.start",
        json!({"requestJson": request("canonical.full")}),
    );
    assert_eq!(started["ok"], true, "{started}");
    let invocation = started["result"]["invocationID"]
        .as_str()
        .unwrap()
        .to_owned();
    let baseline = started["result"]["baselineMaterializedPlanDigest"].clone();
    let evaluate = || {
        call(
            "debug.evaluate",
            json!({"invocationId": invocation, "actionJson": EXECUTE,
                "sourceSha256": SOURCE, "buildSha256": BUILD}),
        )
    };
    let answer = evaluate();
    assert_eq!(answer["ok"], true, "{answer}; {:?}", fakes.calls());
    let result = &answer["result"];
    let attempt = result["evaluations"].as_array().unwrap().last().unwrap();
    let job = attempt["jobID"]
        .as_str()
        .unwrap_or_else(|| panic!("{answer}"));
    assert_eq!(attempt["destructiveEpoch"], 1, "{answer}");
    assert_eq!(result["destructiveEpochsUsed"], 1, "{answer}");
    let suffix = &invocation[invocation.len() - 12..];
    assert_eq!(
        attempt["requestID"],
        format!("debug-{suffix}-e1"),
        "{answer}"
    );
    let key = attempt["idempotencyKey"].as_str().unwrap();
    assert!(
        key.starts_with(&format!("runtime-debug-{suffix}-e1-")),
        "{key}"
    );
    // The permit is durable beside the invocation documents, and the Job's
    // authorized plan pins the attempt: its digest is not the seed's.
    assert!(
        state
            .join("runtime-debug-attempts")
            .join(format!("{key}.json"))
            .exists()
    );
    let status = call("job.status", json!({"jobId": job}));
    let shown = call("job.show", json!({"jobId": job}));
    let digest = &shown["result"]["materializedPlanDigest"];
    assert!(digest.is_string(), "{shown}");
    assert_ne!(*digest, baseline, "{shown}");
    let performs = |calls: &(Vec<String>, Vec<String>)| {
        calls
            .0
            .iter()
            .filter(|call| call.starts_with("perform "))
            .count()
    };
    let calls = fakes.calls();
    assert_eq!(performs(&calls), 1, "{calls:?}");
    if unknown {
        assert_eq!(attempt["outcome"], "outcomeUnknown", "{answer}");
        assert_eq!(
            attempt["disposition"], "awaitingRuntimeRecoveryProof",
            "{answer}"
        );
        assert_eq!(result["state"], "active", "{answer}");
        assert_eq!(status["result"]["state"], "waitingForRecovery", "{status}");
        // The unknown Job is never run again.
        let again = call("job.run", json!({"jobId": job}));
        assert_eq!(again["ok"], false, "{again}");
        assert_eq!(fakes.calls(), calls, "an unknown intent must never replay");
        return;
    }
    assert_eq!(attempt["outcome"], "succeeded", "{answer}");
    assert_eq!(attempt["disposition"], "succeeded", "{answer}");
    assert_eq!(
        attempt["detail"], "Runtime Job terminal state succeeded",
        "{answer}"
    );
    assert_eq!(result["state"], "succeeded", "{answer}");
    assert_eq!(status["result"]["state"], "succeeded", "{status}");
    // A settled invocation executes nothing more.
    let again = evaluate();
    assert_eq!(again["ok"], false, "{again}");
    assert_eq!(
        fakes.calls(),
        calls,
        "a settled invocation never redispatches"
    );
}
