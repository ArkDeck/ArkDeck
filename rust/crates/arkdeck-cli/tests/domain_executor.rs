//! Swift's client-side executor replayed on the Rust port
//! (`arkdeck_cli::domain_executor`). Each scenario of
//! `rust/tests/fixtures/domain-executor`, recorded by
//! `CLIDomainExecutorOracleContractTests`, runs the port against an in-memory
//! Runtime that answers as the Swift test's scripted peer did: each
//! connection's `health` preflight as the current Runtime answers it, unless
//! the script's next entry is `health`, and each business frame from the
//! script, whose next entry must name its method. The clock counts, as the
//! Swift test's did. The port must send the same frames and end the same way.
use arkdeck_cli::domain_executor::{
    ClientFailure, ExecutionRequest, Executor, ExecutorError, Outcome, Runtime, evidence_facts,
};
use arkdeck_client::Client;
use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
use serde_json::{Map, Value, json};
use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::path::Path;
use std::rc::Rc;
use std::time::Duration;

fn scenarios() -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/domain-executor/scenarios.json");
    serde_json::from_slice::<Value>(&std::fs::read(path).unwrap())
        .unwrap()
        .as_array()
        .unwrap()
        .clone()
}

/// Swift's labels for random identities.
fn label(id: &str) -> String {
    let uuid = |text: &str, lower: bool| {
        text.len() == 36
            && text.bytes().enumerate().all(|(index, byte)| {
                if [8, 13, 18, 23].contains(&index) {
                    byte == b'-'
                } else if lower {
                    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
                } else {
                    byte.is_ascii_digit() || (b'A'..=b'F').contains(&byte)
                }
            })
    };
    match id.strip_prefix("agent-") {
        Some(rest) if uuid(rest, true) => "agent-<uuid>".into(),
        _ if uuid(id, false) => "<UUID>".into(),
        _ => id.into(),
    }
}

/// `value` with each resume token labelled, as the oracle records them.
fn labelled(value: &Value) -> Value {
    match value {
        Value::String(text) => {
            let mut output = String::new();
            let mut rest = text.as_str();
            while let Some(at) = rest.find("resume-") {
                output.push_str(&rest[..at + 7]);
                rest = &rest[at + 7..];
                if rest.len() >= 36 && label(&rest[..36].to_uppercase()) == "<UUID>" {
                    output.push_str("<uuid>");
                    rest = &rest[36..];
                }
            }
            output.push_str(rest);
            Value::String(output)
        }
        Value::Array(values) => Value::Array(values.iter().map(labelled).collect()),
        Value::Object(fields) => Value::Object(
            fields
                .iter()
                .map(|(key, value)| (key.clone(), labelled(value)))
                .collect(),
        ),
        other => other.clone(),
    }
}

#[derive(Clone)]
enum Reply {
    Result(Value),
    Error(Value),
    Close,
}

struct Shared {
    script: RefCell<VecDeque<(String, Reply)>>,
    sent: RefCell<Vec<Value>>,
    connections: Cell<usize>,
}

/// One connection's conversation: each complete request frame is logged and
/// answered, or the connection closes.
struct Conversation {
    shared: Rc<Shared>,
    incoming: Vec<u8>,
    outgoing: VecDeque<u8>,
}

fn health() -> Value {
    json!({"status": "ok", "protocolVersion": PROTOCOL_VERSION,
        "contractIdentity": CONTRACT_IDENTITY, "publishedMethods": METHODS,
        "catalogDigest": CATALOG_DIGEST, "providers": []})
}

impl Conversation {
    fn answer(&mut self, frame: &[u8]) {
        let frame: Value = serde_json::from_slice(frame).unwrap();
        let (id, method) = (
            frame["id"].as_str().unwrap().to_owned(),
            frame["method"].as_str().unwrap().to_owned(),
        );
        let label = label(&id);
        let mut logged = Map::from_iter([
            ("method".to_owned(), json!(method)),
            ("id".to_owned(), json!(label)),
        ]);
        if let Some(params) = frame.get("params") {
            logged.insert("params".into(), params.clone());
        }
        self.shared.sent.borrow_mut().push(Value::Object(logged));
        let preflight = method == "health" && label == "<UUID>";
        let mut script = self.shared.script.borrow_mut();
        let reply = if method == "health"
            && !(preflight && script.front().is_some_and(|(next, _)| next == "health"))
        {
            Reply::Result(health())
        } else {
            match script.front() {
                Some((next, _)) if *next == method => script.pop_front().unwrap().1,
                _ => {
                    self.shared
                        .sent
                        .borrow_mut()
                        .push(json!({"unscripted": method}));
                    Reply::Close
                }
            }
        };
        let response = match reply {
            Reply::Result(result) => json!({"id": id, "ok": true, "result": result}),
            Reply::Error(error) => json!({"id": id, "ok": false, "error": error}),
            Reply::Close => {
                self.outgoing.clear();
                return;
            }
        };
        let mut bytes = serde_json::to_vec(&response).unwrap();
        bytes.push(b'\n');
        self.outgoing.extend(bytes);
    }
}

impl Write for Conversation {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.incoming.extend_from_slice(bytes);
        while let Some(end) = self.incoming.iter().position(|byte| *byte == b'\n') {
            let frame: Vec<u8> = self.incoming.drain(..=end).collect();
            self.answer(&frame[..frame.len() - 1]);
        }
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Read for Conversation {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
        let count = bytes.len().min(self.outgoing.len());
        for (slot, byte) in bytes.iter_mut().zip(self.outgoing.drain(..count)) {
            *slot = byte;
        }
        Ok(count)
    }
}

struct Scripted {
    shared: Rc<Shared>,
    absent: bool,
}

impl Runtime for Scripted {
    type Stream = Conversation;

    fn connect(&mut self, _remaining: Duration) -> Result<Client<Conversation>, ClientFailure> {
        if self.absent {
            return Err(ClientFailure::ConnectFailed(
                "connect failed: errno 2".into(),
            ));
        }
        self.shared
            .connections
            .set(self.shared.connections.get() + 1);
        Ok(Client::new(Conversation {
            shared: self.shared.clone(),
            incoming: Vec::new(),
            outgoing: VecDeque::new(),
        }))
    }
}

/// The oracle's record of a thrown `AgentClientError`: its case and fields.
fn structure(failure: &ClientFailure) -> Value {
    match failure {
        ClientFailure::ConnectFailed(message) => {
            json!({"case": "connectFailed", "message": message})
        }
        ClientFailure::Transport(message) => json!({"case": "transport", "message": message}),
        ClientFailure::MalformedResponse(message) => {
            json!({"case": "malformedResponse", "message": message})
        }
        ClientFailure::DeadlineExceeded => json!({"case": "deadlineExceeded"}),
        ClientFailure::DaemonError { code, message } => {
            json!({"case": "daemonError", "code": code, "message": message})
        }
        ClientFailure::StructuredDaemonError {
            code,
            message,
            details,
        } => json!({"case": "structuredDaemonError", "code": code, "message": message,
            "details": details}),
    }
}

fn request(value: &Value) -> ExecutionRequest {
    ExecutionRequest {
        operation_id: value["operationID"].as_str().unwrap().into(),
        operation_version: value["operationVersion"].as_i64(),
        inputs: value["inputs"].as_object().unwrap().clone(),
        capability: value["capabilityReference"].as_str().map(str::to_owned),
        target: value["targetID"].as_str().map(str::to_owned),
        maximum_wait_seconds: value["maximumWaitSeconds"].as_u64().unwrap(),
        execution_id: value["executionID"].as_str().unwrap().into(),
    }
}

/// The port's run of one scenario, as the oracle records Swift's.
fn replay(scenario: &Value) -> Map<String, Value> {
    let script = scenario["script"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| {
            let method = entry["method"].as_str().unwrap().to_owned();
            let reply = if let Some(result) = entry.get("result") {
                Reply::Result(result.clone())
            } else if let Some(error) = entry.get("error") {
                Reply::Error(error.clone())
            } else {
                Reply::Close
            };
            (method, reply)
        })
        .collect();
    let shared = Rc::new(Shared {
        script: RefCell::new(script),
        sent: RefCell::new(Vec::new()),
        connections: Cell::new(0),
    });
    let reads = Rc::new(Cell::new(0));
    let clock = {
        let reads = reads.clone();
        move || {
            reads.set(reads.get() + 1);
            format!("2026-09-25T00:00:{:02}Z", reads.get())
        }
    };
    let state = std::env::temp_dir().join(format!(
        "arkdeck-domain-executor-{}",
        arkdeck_platform::random_bytes::<8>()
            .unwrap()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    ));
    let mut executor = Executor::new(
        Scripted {
            shared: shared.clone(),
            absent: scenario["runtimeAbsent"] == true,
        },
        clock,
        state.join("agent-runtime"),
    );
    let mut fields = Map::new();
    match executor.run(&request(&scenario["request"])) {
        Ok(Outcome::Completed(receipt)) => {
            fields.insert(
                "outcome".into(),
                json!({"kind": "completed", "receipt": receipt}),
            );
        }
        Ok(Outcome::Paused { action, receipt }) => {
            fields.insert(
                "outcome".into(),
                json!({"kind": "awaitingHumanAction", "action": action, "receipt": receipt}),
            );
        }
        Ok(Outcome::Failed { reason, receipt }) => {
            fields.insert(
                "outcome".into(),
                json!({"kind": "failed", "reason": reason, "receipt": receipt}),
            );
        }
        Err(ExecutorError::Client(failure)) => {
            let error = failure.cli_error();
            fields.insert(
                "error".into(),
                json!({"type": "AgentClientError", "value": structure(&failure)}),
            );
            fields.insert(
                "cli".into(),
                json!({"code": error.code, "message": error.message, "details": error.details}),
            );
        }
        Err(error @ ExecutorError::Executor(_)) => {
            fields.insert(
                "error".into(),
                json!({"type": "RuntimeAgentExecutorError", "value": error.description()}),
            );
        }
        Err(error @ ExecutorError::Control(_)) => {
            fields.insert(
                "error".into(),
                json!({"type": "AgentExecutionControlFailure", "value": error.description()}),
            );
        }
    }
    let directory = state.join("agent-runtime");
    let mut pending = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&directory) {
        let mut names: Vec<String> = entries
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        for name in names {
            let content: Value =
                serde_json::from_slice(&std::fs::read(directory.join(&name)).unwrap()).unwrap();
            pending.push(json!({"file": name, "content": content}));
        }
    }
    let _ = std::fs::remove_dir_all(&state);
    fields.insert("pending".into(), Value::Array(pending));
    fields.insert("sent".into(), Value::Array(shared.sent.borrow().clone()));
    fields.insert("connections".into(), json!(shared.connections.get()));
    fields.insert(
        "unusedScript".into(),
        json!(
            shared
                .script
                .borrow()
                .iter()
                .map(|(method, _)| method.clone())
                .collect::<Vec<_>>()
        ),
    );
    fields.insert("clockReads".into(), json!(reads.get()));
    match labelled(&Value::Object(fields)) {
        Value::Object(fields) => fields,
        _ => unreachable!(),
    }
}

#[test]
fn each_scenario_replays_as_swifts_executor_ran_it() {
    let mut differences = Vec::new();
    for scenario in scenarios() {
        let name = scenario["name"].as_str().unwrap().to_owned();
        let port = replay(&scenario);
        for key in [
            "sent",
            "connections",
            "unusedScript",
            "clockReads",
            "pending",
            "outcome",
        ] {
            let swift = scenario.get(key).cloned().unwrap_or(Value::Null);
            let rust = port.get(key).cloned().unwrap_or(Value::Null);
            if swift != rust {
                differences.push(format!("{name} {key}:\n  swift {swift}\n  rust  {rust}"));
            }
        }
        match scenario["error"]["type"].as_str() {
            Some("AgentClientError") => {
                if port["error"] != scenario["error"] {
                    differences.push(format!(
                        "{name} error: swift {} rust {}",
                        scenario["error"], port["error"]
                    ));
                } else {
                    for key in ["code", "message", "details"] {
                        if scenario["cli"][key] != port["cli"][key] {
                            differences.push(format!(
                                "{name} cli {key}: swift {} rust {}",
                                scenario["cli"][key], port["cli"][key]
                            ));
                        }
                    }
                }
            }
            Some(kind) => {
                if port["error"] != json!({"type": kind, "value": scenario["error"]["value"]}) {
                    differences.push(format!(
                        "{name} error: swift {} rust {}",
                        scenario["error"], port["error"]
                    ));
                }
            }
            None => {
                if port.contains_key("error") {
                    differences.push(format!("{name} error: rust {}", port["error"]));
                }
            }
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}

/// Swift's reading of each evidence answer (`rust/tests/fixtures/
/// domain-executor-evidence`, recorded by
/// `CLIDomainExecutorEvidenceOracleContractTests`): the trusted facts as Swift
/// encodes them again, or its refusal. A `DecodingError`'s text is Swift's
/// own; this port answers its own words there.
#[test]
fn each_evidence_answer_is_read_as_swifts_executor_reads_it() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/domain-executor-evidence/cases.json");
    let cases: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    let cases = cases.as_array().unwrap();
    assert!(cases.len() > 60, "{} cases", cases.len());
    let (mut read, mut refused) = (0, 0);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        match (evidence_facts(&case["value"]), case.get("facts")) {
            (Ok(facts), Some(swift)) => {
                assert_eq!(Value::Object(facts), *swift, "{name}");
                read += 1;
            }
            (Err(text), None) => {
                let expected = match case["refusal"].as_str().unwrap() {
                    "decoding" => "the Job evidence did not decode as the Runtime's trusted facts",
                    refusal => refusal,
                };
                assert_eq!(text, expected, "{name}");
                refused += 1;
            }
            (rust, _) => panic!("{name}: Swift {case}, here {rust:?}"),
        }
    }
    assert!(
        read >= 20 && refused >= 30,
        "{read} read, {refused} refused"
    );
}
