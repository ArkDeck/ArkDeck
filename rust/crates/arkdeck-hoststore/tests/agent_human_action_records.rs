//! The Rust agent execution owner over the execution records Swift's owner
//! left in its physical-assistance oracle (`rust/tests/fixtures/agent-human-action`,
//! produced by `AgentHumanActionOracleContractTests`): an execution that waits
//! for a person to pick a device, one abandoned while it waited for a trust
//! prompt, one that completed after a reconnect and one refused before any
//! action. The owner reads them as Swift's does and answers `agent.status`,
//! `agent.list`, `agent.run` and `agent.abandon` for them as the oracle
//! recorded: the waiting execution with its action and the next action that
//! names it, run again as a budget read that answers as it waits, and
//! abandoned with its action expired. Run again once its time has run out, it
//! ends with its action expired, as Swift's `observeBudget` ends it. The
//! identities the oracle labelled (`<har-1>`) read as valid ones of their kind.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_hoststore::{
    AgentEngine, AgentExecutionStore, ArtifactReadStore, JobAdmitter, JobPlanner, JobStore,
    TargetStore,
};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use support::{chmod, fixed_now, fixed_precise_now};

/// The oracle's text with each identity it labelled (`<har-2>`) read as a
/// valid one of its kind (`har-00000000-0000-4000-8000-000000000002`).
fn unlabelled(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(at) = rest.find('<') {
        out.push_str(&rest[..at]);
        let tail = &rest[at + 1..];
        let label = ["har", "resume", "candidate", "obs"]
            .iter()
            .find_map(|kind| {
                let digits = tail.strip_prefix(kind)?.strip_prefix('-')?;
                let end = digits.find('>')?;
                let number: u64 = digits[..end].parse().ok()?;
                Some((
                    format!("{kind}-00000000-0000-4000-8000-{number:012}"),
                    kind.len() + end + 2,
                ))
            });
        match label {
            Some((identity, used)) => {
                out.push_str(&identity);
                rest = &tail[used..];
            }
            None => {
                out.push('<');
                rest = tail;
            }
        }
    }
    out + rest
}

/// The oracle's exchanges, their identities unlabelled.
fn cases(fixture: &Path) -> Value {
    serde_json::from_str(&unlabelled(
        &fs::read_to_string(fixture.join("cases.json")).unwrap(),
    ))
    .unwrap()
}

/// One of the oracle's exchanges, by name.
fn exchange(cases: &Value, name: &str) -> Value {
    cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == name)
        .unwrap_or_else(|| panic!("no exchange {name}"))
        .clone()
}

/// A private root holding the oracle's Target document and its execution
/// records, and the empty Artifact and Job owners beside them.
struct Root(PathBuf);

impl Root {
    fn new(fixture: &Path, name: &str) -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "agent-human-action-records-{name}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        for directory in [
            "",
            "targets-state",
            "artifacts",
            "jobs-state",
            "agent-executions",
        ] {
            let path = root.join(directory);
            fs::create_dir_all(&path).unwrap();
            chmod(&path, 0o700);
        }
        let target = root.join("targets-state/targets.json");
        fs::copy(fixture.join("targets-state/targets.json"), &target).unwrap();
        chmod(&target, 0o600);
        for entry in fs::read_dir(fixture.join("agent-executions")).unwrap() {
            let path = entry.unwrap().path();
            let record = root
                .join("agent-executions")
                .join(path.file_name().unwrap());
            fs::write(&record, unlabelled(&fs::read_to_string(&path).unwrap())).unwrap();
            chmod(&record, 0o600);
        }
        Self(root)
    }

    fn record(&self, name: &str) -> Value {
        serde_json::from_slice(&fs::read(self.0.join("agent-executions").join(name)).unwrap())
            .unwrap()
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// A method's answer, or its refusal's code and message.
type Answer = Result<Value, (String, String)>;

/// The owner's orchestration clock.
type Clock = fn() -> Option<String>;

/// Runs `body` with the agent execution owner over `root` on the clock `now`.
fn owner<T>(root: &Root, now: Clock, body: impl FnOnce(&dyn Fn(&str, Value) -> Answer) -> T) -> T {
    let targets = TargetStore::open(&root.0.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.0.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.0.join("jobs-state")).unwrap();
    let agents = AgentExecutionStore::open(&root.0.join("agent-executions")).unwrap();
    let admitter = JobAdmitter {
        planner: JobPlanner {
            artifacts: Some(&artifacts),
            analyzer: None,
            state_root: &root.0,
            hdc: None,
        },
        jobs: &jobs,
        now: fixed_now,
        authority: None,
    };
    let engine = AgentEngine {
        targets: &targets,
        jobs: &jobs,
        admitter: &admitter,
        now,
    };
    body(&|method, params| {
        agents
            .advance(method, params.as_object().unwrap(), &engine)
            .map(|answer| answer.value)
            .map_err(|error| (error.code, error.message))
    })
}

const AMBIGUOUS: &str =
    "execution-f2c43a6fa56aac7e64e76e036fd10bb45bb28d77d51013efca02783d6f3d8526.json";
const TRUST: &str =
    "execution-9be87d0b82afa6b6f432df5cd89bb755326fea7489acf981de9d32401698e564.json";

#[test]
fn rust_answers_the_swift_executions_that_wait_for_a_person() {
    let fixture = support::fixture("agent-human-action");
    let cases = cases(&fixture);
    let root = Root::new(&fixture, "answers");
    owner(&root, fixed_precise_now, |answer| {
        let call = |method: &str, params: Value| {
            answer(method, params)
                .unwrap_or_else(|(code, message)| panic!("{method}: {code} {message}"))
        };
        let identity = |id: &str| json!({"executionId": id});
        let waiting = exchange(&cases, "ambiguous.run")["answer"]["result"].clone();
        let abandoned = exchange(&cases, "trust.abandon")["answer"]["result"].clone();

        // Read as Swift answered them.
        assert_eq!(call("agent.status", identity("har-ambiguous")), waiting);
        assert_eq!(call("agent.status", identity("har-trust")), abandoned);
        let page = call("agent.list", json!({}));
        let items = page["items"].as_array().unwrap();
        let ids: Vec<&str> = items
            .iter()
            .map(|item| item["executionId"].as_str().unwrap())
            .collect();
        assert_eq!(
            ids,
            ["har-ambiguous", "har-connect", "har-trust", "har-unproven"]
        );
        let without_action = |answer: &Value| {
            let mut item: Map<String, Value> = answer.as_object().unwrap().clone();
            item.remove("humanAction");
            Value::Object(item)
        };
        assert_eq!(items[0], without_action(&waiting));
        assert_eq!(items[2], without_action(&abandoned));
        assert_eq!(items[0]["nextAction"]["kind"], "humanAction");

        // Run again while it waits: a budget read, answered as it waits.
        let mut again = waiting.clone();
        again["generation"] = json!("4");
        assert_eq!(
            call(
                "agent.run",
                exchange(&cases, "ambiguous.run")["params"].clone()
            ),
            again
        );
        assert_eq!(root.record(AMBIGUOUS)["generation"], 4);
        assert_eq!(root.record(AMBIGUOUS)["actions"][0]["status"], "waiting");

        // Abandoned at the generation it answered with: its action expires.
        let gone = call(
            "agent.abandon",
            json!({"executionId": "har-ambiguous", "expectedGeneration": "4"}),
        );
        assert_eq!(gone["state"], "abandoned");
        assert_eq!(gone["generation"], "5");
        assert_eq!(gone["humanAction"], Value::Null);
        assert_eq!(gone["nextAction"], Value::Null);
        let record = root.record(AMBIGUOUS);
        assert_eq!(record["actions"][0]["status"], "expired");
        assert_eq!(record["state"], "abandoned");

        // An abandoned execution run again is answered as it is, without a write.
        let before = fs::read(root.0.join("agent-executions").join(TRUST)).unwrap();
        assert_eq!(
            call("agent.run", exchange(&cases, "trust.run")["params"].clone()),
            exchange(&cases, "trust.rerun")["answer"]["result"]
        );
        assert_eq!(
            fs::read(root.0.join("agent-executions").join(TRUST)).unwrap(),
            before
        );
    });
}

/// At the waiting execution's orchestration deadline, five minutes after the
/// oracle's clock.
fn at_the_deadline() -> Option<String> {
    Some("2026-09-14T00:05:00.000Z".into())
}

/// Behind the waiting execution's durable high-water mark.
fn behind_the_record() -> Option<String> {
    Some("2026-09-13T23:59:59.999Z".into())
}

#[test]
fn a_waiting_execution_out_of_time_ends_with_its_action_expired() {
    let fixture = support::fixture("agent-human-action");
    let run = exchange(&cases(&fixture), "ambiguous.run")["params"].clone();
    let clocks: [(&str, Clock, &str, &str); 2] = [
        (
            "deadline",
            at_the_deadline,
            "budgetExpired",
            "orchestrationBudgetExpired",
        ),
        (
            "clock",
            behind_the_record,
            "clockUntrusted",
            "orchestrationClockUntrusted",
        ),
    ];
    for (name, now, state, code) in clocks {
        let root = Root::new(&fixture, name);
        owner(&root, now, |answer| {
            // The run is refused, and the execution ends in the same write
            // that expires its action.
            assert_eq!(answer("agent.run", run.clone()).unwrap_err().0, code);
            let record = root.record(AMBIGUOUS);
            assert_eq!(record["state"], state);
            assert_eq!(record["failureCode"], code);
            assert_eq!(record["generation"], 4);
            assert_eq!(record["actions"][0]["status"], "expired");
            let status = answer("agent.status", json!({"executionId": "har-ambiguous"})).unwrap();
            assert_eq!(status["state"], state);
            assert_eq!(status["humanAction"], Value::Null);
        });
    }
}
