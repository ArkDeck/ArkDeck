//! `arkdeck device wait` against a fake Runtime, driven by the snapshots Swift
//! recorded (`Fixtures/ControlFrames/device.observations.jsonl`): every read
//! asks the Runtime to prove the exact observation again, the wait ends only
//! when the requested state is proved, and nothing is ever adopted.
// The fake Runtime this leaf is driven against is a Unix socket.
#[cfg(target_os = "macos")]
mod support;

#[cfg(target_os = "macos")]
mod runtime {
    use super::support;
    use serde_json::{Value, json};

    const CANDIDATE: &str = "150100424a544e4600";
    const OBSERVATION: &str = "obs-fa10b603-4bc5-44d0-8492-39184b509cf7";

    /// The recorded snapshot that proves this observation, `Offline`.
    fn snapshot() -> Value {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(
            "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/device.observations.jsonl",
        );
        std::fs::read_to_string(path)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .find(|row| {
                row["ok"] == true
                    && row["result"]["observations"]
                        .as_array()
                        .is_some_and(|rows| !rows.is_empty())
            })
            .expect("a recorded snapshot with an observation")["result"]
            .clone()
    }

    fn following() -> Value {
        json!({"candidate":CANDIDATE,"observationId":OBSERVATION,"observationGeneration":"1"})
    }

    /// One connection per read, each proving the contract first, as Swift's
    /// client makes them.
    fn observations(answers: Vec<Value>) -> Vec<(String, Value, Value)> {
        answers
            .into_iter()
            .map(|answer| {
                (
                    "device.observations".to_owned(),
                    json!({"following": following()}),
                    json!({"ok":true,"result":answer}),
                )
            })
            .collect()
    }

    fn argv<'a>(state: &'a str, timeout: &'a str) -> Vec<&'a str> {
        vec![
            "device",
            "wait",
            "--candidate",
            CANDIDATE,
            "--observation",
            OBSERVATION,
            "--observation-generation",
            "1",
            "--state",
            state,
            "--timeout",
            timeout,
        ]
    }

    #[test]
    fn the_wait_ends_on_the_snapshot_that_proves_the_state() {
        let (output, envelope) =
            support::run(&argv("offline", "5s"), observations(vec![snapshot()]));
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(envelope["command"], "device.wait");
        assert_eq!(
            envelope["result"],
            json!({"schemaVersion":"arkdeck.device-wait/1","snapshotGeneration":"3",
                "observedAtUtc":"2026-08-31T14:00:00Z","state":"offline",
                "observation": snapshot()["observations"][0]})
        );
    }

    #[test]
    fn a_snapshot_in_another_state_is_read_again() {
        let mut other = snapshot();
        other["observations"][0]["authorizationState"] = json!("Connected");
        let (output, envelope) = support::run(
            &argv("offline", "5s"),
            observations(vec![other, snapshot()]),
        );
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(envelope["result"]["state"], "offline");
        assert_eq!(
            envelope["result"]["observation"]["authorizationState"],
            "Offline"
        );
    }

    #[test]
    fn a_runtime_that_does_not_prove_the_original_lifecycle_is_a_conflict() {
        // The published result contract pins each key, so what a Runtime can
        // still get wrong is what it *says*: this one answers a replacement
        // rather than the observation the caller named.
        let mut replaced = snapshot();
        replaced["observations"][0]["observationContinuity"] = json!("relationReplaced");
        let (output, envelope) = support::run(&argv("offline", "5s"), observations(vec![replaced]));
        assert_eq!(output.status.code(), Some(65));
        assert_eq!(envelope["error"]["code"], "resourceConflict");
        assert_eq!(envelope["error"]["details"], following());
        assert_eq!(envelope["command"], "device.wait");
    }

    #[test]
    fn a_snapshot_the_contract_cannot_catch_is_refused_as_malformed() {
        let mut stale = snapshot();
        stale["health"] = json!("stale");
        let (output, envelope) = support::run(&argv("offline", "5s"), observations(vec![stale]));
        assert_eq!(output.status.code(), Some(70));
        assert_eq!(envelope["error"]["code"], "protocolMalformed");
        assert_eq!(
            envelope["error"]["message"],
            "the Runtime returned an invalid device observation snapshot"
        );
    }

    #[test]
    fn the_client_stops_waiting_without_adopting_or_cancelling_anything() {
        let mut other = snapshot();
        other["observations"][0]["authorizationState"] = json!("Connected");
        // The wait stops at its own deadline. Its budget holds the connection,
        // `health` and the first read (the deadline starts before any of
        // them), so it is seconds, not the few backoff steps it covers: inside
        // two seconds the leaf reads at most five times (100, 200, 400 and
        // 800 ms apart), and a slower host simply reads fewer times. More
        // snapshots are offered than it can ask for.
        let (output, envelope) =
            support::run_partial(&argv("offline", "2s"), observations(vec![other; 8]));
        assert_eq!(output.status.code(), Some(75));
        assert_eq!(envelope["error"]["code"], "clientTimeout");
        assert_eq!(
            envelope["error"]["message"],
            "stopped waiting for the exact device observation; no adoption or cancellation was requested"
        );
        let details = &envelope["error"]["details"];
        assert_eq!(details["candidate"], CANDIDATE);
        assert_eq!(details["observationId"], OBSERVATION);
        assert_eq!(details["observationGeneration"], "1");
        assert_eq!(details["requestedState"], "offline");
        assert_eq!(details["newDispatchCount"], 0);
        // Whatever the host's pace, at least one snapshot was proved.
        assert_eq!(details["lastObservedGeneration"], "3");
    }
}
