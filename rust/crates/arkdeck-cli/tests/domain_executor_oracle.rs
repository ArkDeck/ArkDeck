//! The oracle of Swift's client-side `AgentRuntimeExecutor`, which runs the
//! domain leaves (`RuntimeCLI.runDomainOperation`): `rust/tests/fixtures/
//! domain-executor`, recorded by `CLIDomainExecutorOracleContractTests`
//! against a scripted local Runtime answering from Swift's daemon's recorded
//! frames. The Rust port of the domain leaves replays it in the slices that
//! follow. Here the recording is held to its own terms, so that what it says
//! Swift did is what Swift did.
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;

fn scenarios() -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/domain-executor/scenarios.json");
    let text = std::fs::read(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    serde_json::from_slice::<Value>(&text)
        .unwrap()
        .as_array()
        .unwrap()
        .clone()
}

fn name(scenario: &Value) -> &str {
    scenario["name"].as_str().unwrap()
}

/// Each scenario consumed its whole script, and the executor asked for its
/// business frames in the script's order: none was left unanswered or
/// answered by the peer's defaults.
#[test]
fn each_scenario_consumed_exactly_its_script_in_order() {
    let scenarios = scenarios();
    assert_eq!(scenarios.len(), 30);
    for scenario in &scenarios {
        let name = name(scenario);
        assert_eq!(scenario["unusedScript"], json!([]), "{name}");
        let sent = scenario["sent"].as_array().unwrap();
        assert!(
            sent.iter().all(|frame| frame.get("unscripted").is_none()),
            "{name}"
        );
        let business = |frames: &[Value]| -> Vec<String> {
            frames
                .iter()
                .filter(|frame| frame["method"] != "health")
                .map(|frame| frame["method"].as_str().unwrap().to_owned())
                .collect()
        };
        assert_eq!(
            business(sent),
            business(scenario["script"].as_array().unwrap()),
            "{name}"
        );
    }
}

/// The executor's frames are `agent-<uuid>`, the client's own (its preflight
/// and the Artifact pages) `<UUID>`; resume tokens are `resume-<uuid>`. No
/// random identity or temporary path is left in the oracle.
#[test]
fn every_random_identity_is_labelled() {
    let scenarios = scenarios();
    for scenario in &scenarios {
        for frame in scenario["sent"].as_array().unwrap() {
            assert!(
                matches!(frame["id"].as_str(), Some("agent-<uuid>" | "<UUID>")),
                "{}: {frame}",
                name(scenario)
            );
        }
    }
    let text = serde_json::to_string(&scenarios).unwrap();
    assert!(
        !text.match_indices("resume-").any(|(at, _)| {
            text.as_bytes()
                .get(at + 7..at + 15)
                .is_some_and(|digits| digits.iter().all(u8::is_ascii_hexdigit))
        }),
        "an unlabelled resume token"
    );
    assert!(!text.contains("/var/folders/") && !text.contains("/private/tmp/"));
}

/// The scenarios reach every way Swift's executor ends a run, and each pause
/// persisted exactly its one resume record and is refused by the CLI as a
/// person's action.
#[test]
fn the_scenarios_cover_every_way_a_run_ends() {
    let mut endings: BTreeMap<String, usize> = BTreeMap::new();
    let mut actions: BTreeMap<String, usize> = BTreeMap::new();
    for scenario in scenarios() {
        let name = name(&scenario).to_owned();
        let ending = match scenario["outcome"]["kind"].as_str() {
            Some(kind) => kind.to_owned(),
            None => format!("thrown {}", scenario["error"]["type"].as_str().unwrap()),
        };
        if ending == "awaitingHumanAction" {
            *actions
                .entry(
                    scenario["outcome"]["action"]["kind"]
                        .as_str()
                        .unwrap()
                        .into(),
                )
                .or_default() += 1;
            assert_eq!(scenario["pending"].as_array().unwrap().len(), 1, "{name}");
            assert_eq!(
                scenario["pending"][0]["file"], "resume-<uuid>.json",
                "{name}"
            );
            assert_eq!(scenario["cli"]["code"], "humanActionRequired", "{name}");
        } else {
            assert_eq!(scenario["pending"], json!([]), "{name}");
        }
        if ending == "thrown AgentClientError" {
            // What the CLI names it, as `job.submit`'s failure.
            assert_eq!(scenario["cli"]["details"]["method"], "job.submit", "{name}");
        }
        *endings.entry(ending).or_default() += 1;
    }
    assert_eq!(
        endings,
        BTreeMap::from([
            ("awaitingHumanAction".to_owned(), 9),
            ("completed".to_owned(), 4),
            ("failed".to_owned(), 8),
            ("thrown AgentClientError".to_owned(), 4),
            ("thrown RuntimeAgentExecutorError".to_owned(), 5),
        ])
    );
    assert_eq!(
        actions,
        BTreeMap::from([
            ("physicalReconnect".to_owned(), 5),
            ("selectTarget".to_owned(), 2),
            ("trustDevice".to_owned(), 2),
        ])
    );
}
