//! The domain leaves (`arkdeck <domain> <verb>`) replayed through the CLI
//! process against Swift's recorded executor scenarios
//! (`rust/tests/fixtures/domain-executor`, `CLIDomainExecutorOracleContractTests`,
//! whose owners are `AgentRuntimeExecutor.run`, `RuntimeCLI.emitAgentOutcome`
//! and `CLIRuntimeSession.mapped`).
//!
//! A fake Runtime on a private socket answers as the Swift test's scripted
//! peer did: each connection's `health` preflight as the current Runtime
//! answers it, unless the script's next entry is `health`, and each business
//! frame from the script, whose next entry must name its method. The CLI must
//! send the same frames over as many connections, persist the same pending
//! record, and end as Swift's CLI ends: the receipt, the failure envelope with
//! Swift's code, words and details, or the plain diagnostic and exit status.
#![cfg(target_os = "macos")]

use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
use serde_json::{Map, Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

fn scenarios() -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/domain-executor/scenarios.json");
    serde_json::from_slice::<Value>(&std::fs::read(path).unwrap())
        .unwrap()
        .as_array()
        .unwrap()
        .clone()
}

fn registry() -> Vec<Value> {
    serde_json::from_str::<Value>(include_str!("../src/command_registry.json")).unwrap()["commands"]
        .as_array()
        .unwrap()
        .clone()
}

/// The Catalog operation the registry declares for `leaf`.
fn operation(leaf: &str) -> String {
    registry()
        .into_iter()
        .find(|entry| entry["command"] == leaf)
        .unwrap()["catalogOperation"]
        .as_str()
        .unwrap()
        .to_owned()
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

/// `actual` with each clock reading of the recording taken as recorded: where
/// `expected` holds the oracle's counting clock, `actual` must hold a
/// whole-second UTC timestamp, which is then compared as the recorded one.
fn clocked(actual: &Value, expected: &Value) -> Value {
    let recorded = |text: &str| text.starts_with("2026-09-25T00:00:") && text.len() == 20;
    let timestamp = |text: &str| {
        text.len() == 20
            && text.ends_with('Z')
            && text.bytes().enumerate().all(|(index, byte)| match index {
                4 | 7 => byte == b'-',
                10 => byte == b'T',
                13 | 16 => byte == b':',
                19 => byte == b'Z',
                _ => byte.is_ascii_digit(),
            })
    };
    match (actual, expected) {
        (Value::String(now), Value::String(then)) if recorded(then) && timestamp(now) => {
            Value::String(then.clone())
        }
        (Value::Array(values), Value::Array(recorded)) => Value::Array(
            values
                .iter()
                .enumerate()
                .map(|(index, value)| match recorded.get(index) {
                    Some(recorded) => clocked(value, recorded),
                    None => value.clone(),
                })
                .collect(),
        ),
        (Value::Object(fields), Value::Object(recorded)) => Value::Object(
            fields
                .iter()
                .map(|(key, value)| {
                    let value = match recorded.get(key) {
                        Some(recorded) => clocked(value, recorded),
                        None => value.clone(),
                    };
                    (key.clone(), value)
                })
                .collect(),
        ),
        (other, _) => other.clone(),
    }
}

fn health() -> Value {
    json!({"status": "ok", "protocolVersion": PROTOCOL_VERSION,
        "contractIdentity": CONTRACT_IDENTITY, "publishedMethods": METHODS,
        "catalogDigest": CATALOG_DIGEST, "providers": []})
}

/// What the fake Runtime saw: every frame, labelled, and its connections.
#[derive(Default)]
struct Seen {
    sent: Vec<Value>,
    connections: usize,
}

/// A private directory, removed however the test ends.
struct Root(PathBuf);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn private_root() -> Root {
    let root = std::fs::canonicalize("/tmp").unwrap().join(format!(
        "arkdeck-cli-domain-{:032x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    ));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&root)
        .unwrap();
    Root(root)
}

/// Serves `script` on `socket` until the CLI has exited, one connection at a
/// time, as the scripted peer answered.
fn serve(
    socket: &Path,
    script: Vec<Value>,
    exited: Arc<AtomicBool>,
) -> std::thread::JoinHandle<Seen> {
    let listener = UnixListener::bind(socket).unwrap();
    std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600)).unwrap();
    listener.set_nonblocking(true).unwrap();
    std::thread::spawn(move || {
        let mut script: std::collections::VecDeque<Value> = script.into();
        let mut seen = Seen::default();
        loop {
            let stream = match listener.accept() {
                Ok((stream, _)) => stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    if exited.load(Ordering::SeqCst) {
                        // Every connection the CLI made is already queued.
                        match listener.accept() {
                            Ok((stream, _)) => stream,
                            Err(_) => return seen,
                        }
                    } else {
                        std::thread::sleep(std::time::Duration::from_millis(5));
                        continue;
                    }
                }
                Err(error) => panic!("{error}"),
            };
            seen.connections += 1;
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(10)))
                .unwrap();
            let mut reader = BufReader::new(stream);
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 {
                    break;
                }
                let frame: Value = serde_json::from_str(&line).unwrap();
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
                seen.sent.push(Value::Object(logged));
                let preflight = method == "health" && label == "<UUID>";
                let reply = if method == "health"
                    && !(preflight
                        && script
                            .front()
                            .is_some_and(|next| next["method"] == "health"))
                {
                    Some(json!({"id": id, "ok": true, "result": health()}))
                } else if script.front().is_some_and(|next| next["method"] == method) {
                    let entry = script.pop_front().unwrap();
                    if let Some(result) = entry.get("result") {
                        Some(json!({"id": id, "ok": true, "result": result}))
                    } else {
                        entry
                            .get("error")
                            .map(|error| json!({"id": id, "ok": false, "error": error}))
                    }
                } else {
                    seen.sent.push(json!({"unscripted": method}));
                    None
                };
                let Some(reply) = reply else { break };
                if writeln!(reader.get_mut(), "{reply}").is_err() {
                    break;
                }
            }
        }
    })
}

/// The CLI's argv for `request` on `leaf`.
fn argv(leaf: &str, request: &Value, root: &Path) -> Vec<String> {
    let mut argv: Vec<String> = leaf.split('.').map(str::to_owned).collect();
    let text = |key: &str| request[key].as_str().map(str::to_owned);
    if let Some(id) = text("executionID") {
        argv.extend(["--execution-id".into(), id]);
    }
    if let Some(target) = text("targetID") {
        argv.extend(["--target".into(), target]);
    }
    if let Some(capability) = text("capabilityReference") {
        argv.extend(["--capability".into(), capability]);
    }
    if request["inputs"]
        .as_object()
        .is_some_and(|inputs| !inputs.is_empty())
    {
        let path = root.join("inputs.json");
        std::fs::write(&path, serde_json::to_vec(&request["inputs"]).unwrap()).unwrap();
        argv.extend(["--inputs-file".into(), path.to_str().unwrap().to_owned()]);
    }
    argv
}

struct Run {
    output: Output,
    seen: Seen,
    pending: Vec<Value>,
}

/// The CLI run for `scenario` on `leaf` in `mode`, against the scripted
/// Runtime, or against no Runtime at all.
fn run(scenario: &Value, leaf: &str, mode: &[&str]) -> Run {
    let root = private_root();
    let socket = root.0.join("a.sock");
    let exited = Arc::new(AtomicBool::new(false));
    let server = (scenario["runtimeAbsent"] != true).then(|| {
        serve(
            &socket,
            scenario["script"].as_array().unwrap().clone(),
            exited.clone(),
        )
    });
    let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(argv(leaf, &scenario["request"], &root.0))
        .args(mode)
        .arg("--socket")
        .arg(&socket)
        .output()
        .unwrap();
    exited.store(true, Ordering::SeqCst);
    let seen = server
        .map(|server| server.join().unwrap())
        .unwrap_or_default();
    let state = root.0.join("agent-runtime");
    let mut pending: Vec<Value> = std::fs::read_dir(&state)
        .map(|entries| {
            entries
                .map(|entry| {
                    let path = entry.unwrap().path();
                    json!({"file": path.file_name().unwrap().to_str().unwrap(),
                        "content": serde_json::from_slice::<Value>(&std::fs::read(&path).unwrap())
                            .unwrap()})
                })
                .collect()
        })
        .unwrap_or_default();
    pending.sort_by_key(|entry| entry["file"].to_string());
    Run {
        output,
        seen,
        pending: labelled(&Value::Array(pending)).as_array().unwrap().clone(),
    }
}

/// `scenario` with its operation replaced by `leaf`'s, everywhere it is
/// named: the request, the frames, the answers and the expected ends.
fn retargeted(scenario: &Value, leaf: &str) -> Value {
    let from = format!(
        "{}@{}",
        scenario["request"]["operationID"].as_str().unwrap(),
        scenario["request"]["operationVersion"]
    );
    let to = operation(leaf);
    let (from_id, to_id) = (
        from.split_once('@').unwrap().0,
        to.split_once('@').unwrap().0,
    );
    assert_eq!(
        from.split_once('@').unwrap().1,
        to.split_once('@').unwrap().1
    );
    serde_json::from_str(
        &serde_json::to_string(scenario)
            .unwrap()
            .replace(&format!("\"{from_id}\""), &format!("\"{to_id}\""))
            .replace(&format!("\\\"{from_id}\\\""), &format!("\\\"{to_id}\\\""))
            .replace(&from, &to),
    )
    .unwrap()
}

/// One scenario's run through `leaf`, held to the oracle.
fn replay(scenario: &Value, leaf: &str) -> Result<(), String> {
    let name = scenario["name"].as_str().unwrap();
    let scenario = retargeted(scenario, leaf);
    let run = run(&scenario, leaf, &["--output", "json"]);
    let stdout = String::from_utf8_lossy(&run.output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&run.output.stderr).into_owned();
    let context = format!("{name} on {leaf}: stdout {stdout} stderr {stderr}");
    let check = |same: bool, what: &str| {
        if same {
            Ok(())
        } else {
            Err(format!("{what} differs: {context}"))
        }
    };
    if let Some(sent) = scenario.get("sent") {
        check(
            &labelled(&Value::Array(run.seen.sent.clone())) == sent,
            "frames",
        )?;
    }
    check(
        scenario["connections"].as_u64() == Some(run.seen.connections as u64),
        "connections",
    )?;
    let expected = scenario["pending"].as_array().unwrap();
    check(
        run.pending.len() == expected.len()
            && run
                .pending
                .iter()
                .zip(expected)
                .all(|(actual, expected)| &clocked(actual, expected) == expected),
        "pending records",
    )?;
    let root = leaf.split('.').next().unwrap();
    let envelope: Value = serde_json::from_slice(&run.output.stdout).unwrap_or(Value::Null);
    if let Some(cli) = scenario.get("cli") {
        // A refusal: Swift's failure envelope.
        check(
            envelope["ok"] == false && envelope["command"] == leaf,
            "envelope",
        )?;
        let error = labelled(&envelope["error"]);
        check(
            error["code"] == cli["code"]
                && error["message"] == cli["message"]
                && error["details"] == cli["details"],
            "refusal",
        )?;
        let exit = arkdeck_cli::error_registry::category(cli["code"].as_str().unwrap())
            .map(arkdeck_cli::error_registry::ExitCategory::exit_code);
        return check(
            exit.is_some() && run.output.status.code() == exit.map(i32::from),
            "exit",
        );
    }
    if let Some(error) = scenario.get("error") {
        // An executor error escapes the handler: nothing on stdout.
        return check(
            run.output.stdout.is_empty()
                && run.output.status.code() == Some(1)
                && stderr == format!("arkdeck {root}: {}\n", error["value"].as_str().unwrap()),
            "plain failure",
        );
    }
    let outcome = &scenario["outcome"];
    check(
        envelope["ok"] == true && envelope["command"] == leaf,
        "envelope",
    )?;
    let receipt = clocked(&labelled(&envelope["result"]), &outcome["receipt"]);
    check(receipt == outcome["receipt"], "receipt")?;
    match outcome["kind"].as_str().unwrap() {
        "completed" => check(
            run.output.status.code() == Some(0) && stderr.is_empty(),
            "exit",
        ),
        "failed" => check(
            run.output.status.code() == Some(1)
                && stderr == format!("arkdeck {root}: {}\n", outcome["reason"].as_str().unwrap()),
            "failed run's exit",
        ),
        other => Err(format!("unexpected outcome {other}: {context}")),
    }
}

/// Every scenario as recorded, through the leaf Swift ran it through
/// (`workspace build`, `workspace patch` or `input tap`).
/// `capabilityWithoutVersion` names no version, which only
/// `agent run --operation` can do: a leaf's registry operation is versioned.
#[test]
fn every_scenario_replays_through_its_own_leaf() {
    let mut failures = Vec::new();
    let mut replayed = 0;
    for scenario in scenarios()
        .iter()
        .filter(|scenario| scenario["request"].get("operationVersion").is_some())
    {
        let leaf = scenario["leaf"].as_str().unwrap();
        assert!(arkdeck_cli::domain_leaves::serves(leaf), "{leaf}");
        replayed += 1;
        if let Err(failure) = replay(scenario, leaf) {
            failures.push(failure);
        }
    }
    assert_eq!(replayed, 29);
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

/// The leaves Swift gives a capture preset.
const PRESETS: [&str; 5] = [
    "screen.capture",
    "ui-dump.capture",
    "ui-dump.component-detail",
    "debug.logs",
    "trace.capture",
];

fn preset_cases() -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/capture-presets/cases.json");
    serde_json::from_slice::<Value>(&std::fs::read(path).unwrap())
        .unwrap()
        .as_array()
        .unwrap()
        .clone()
}

/// Swift's recorded capture presets (`CLICapturePresetOracleContractTests`,
/// `rust/tests/fixtures/capture-presets`), through the CLI. An accepted case
/// runs a recorded device capture whose submitted inputs are the preset's own,
/// never the caller's; everything else it sends and answers is the recording.
/// A refused case is `invalidInput` with Swift's words, before any connection.
#[test]
fn a_capture_preset_submits_swifts_preset_inputs() {
    let cases = preset_cases();
    assert!(cases.len() > 50);
    let mut accepted = 0;
    for case in &cases {
        let leaf = case["path"]
            .as_array()
            .unwrap()
            .iter()
            .map(|token| token.as_str().unwrap())
            .collect::<Vec<_>>()
            .join(".");
        if !PRESETS.contains(&leaf.as_str()) {
            // A leaf without a preset keeps the caller's inputs.
            assert_eq!(case["presetInputs"], case["inputs"], "{}", case["name"]);
            continue;
        }
        let mut scenario = retargeted(&scenario("explicitTargetConnected"), &leaf);
        scenario["request"]["inputs"] = case["inputs"].clone();
        let name = case["name"].as_str().unwrap();
        if let Some(refusal) = case.get("refusal") {
            let run = run(&scenario, &leaf, &["--output", "json"]);
            let envelope: Value = serde_json::from_slice(&run.output.stdout).unwrap();
            assert_eq!(run.output.status.code(), Some(65), "{name}");
            assert_eq!(envelope["error"]["code"], "invalidInput", "{name}");
            assert_eq!(&envelope["error"]["message"], refusal, "{name}");
            assert_eq!(run.seen.connections, 0, "{name}");
            continue;
        }
        accepted += 1;
        // The recording, with the preset's inputs in the submitted request.
        let mut sent = scenario["sent"].as_array().unwrap().clone();
        for frame in &mut sent {
            if frame["method"] == "job.submit" {
                let mut request: Value =
                    serde_json::from_str(frame["params"]["requestJson"].as_str().unwrap()).unwrap();
                request["inputs"] = case["presetInputs"].clone();
                frame["params"]["requestJson"] = json!(request.to_string());
            }
        }
        let run = run(&scenario, &leaf, &["--output", "json"]);
        assert_eq!(run.output.status.code(), Some(0), "{name}");
        let parsed = |frames: &[Value]| -> Vec<Value> {
            frames
                .iter()
                .map(|frame| {
                    let mut frame = frame.clone();
                    if let Some(text) = frame["params"]["requestJson"].as_str() {
                        frame["params"]["requestJson"] = serde_json::from_str(text).unwrap();
                    }
                    frame
                })
                .collect()
        };
        assert_eq!(
            parsed(
                labelled(&Value::Array(run.seen.sent.clone()))
                    .as_array()
                    .unwrap()
            ),
            parsed(&sent),
            "{name}"
        );
    }
    assert!(accepted >= 10, "{accepted}");
}

/// Every served leaf, each driving the scenarios whose ending the operation's
/// own name does not decide, in turn: the executor's path is chosen by what
/// `operation.describe` answers (host scope or device target), so a recorded
/// run replays through any leaf with its operation named instead.
/// `hostArtifactConsumerKeepsItsTarget` is decided by the name
/// (`workspace.apply-patch@1` keeps its lease's target), and
/// `capabilityWithoutVersion` names no version.
#[test]
fn every_leaf_replays_swifts_recorded_runs() {
    // A capture preset replaces the recorded inputs with its own, so its
    // leaves replay in `a_capture_preset_submits_swifts_preset_inputs`.
    let leaves: Vec<&str> = arkdeck_cli::domain_leaves::SERVED
        .iter()
        .copied()
        .filter(|leaf| !PRESETS.contains(leaf))
        .collect();
    let scenarios: Vec<Value> = scenarios()
        .into_iter()
        .filter(|scenario| {
            scenario["name"] != "hostArtifactConsumerKeepsItsTarget"
                && scenario["request"].get("operationVersion").is_some()
        })
        .collect();
    assert_eq!(scenarios.len(), 28);
    let runs = leaves.len().max(scenarios.len());
    let mut failures = Vec::new();
    for index in 0..runs {
        let leaf = leaves[index % leaves.len()];
        if let Err(failure) = replay(&scenarios[index % scenarios.len()], leaf) {
            failures.push(failure);
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

fn scenario(name: &str) -> Value {
    scenarios()
        .into_iter()
        .find(|scenario| scenario["name"] == name)
        .unwrap()
}

/// The human and legacy renderings of each ending, which the oracle's machine
/// answers do not show: a completed run is its receipt (pretty, in the human
/// rendering), a failed one only its reason, and a pause the action and how
/// to resume it on stderr before the refusal.
#[test]
fn each_ending_renders_as_swifts_handler_renders_it() {
    let leaf = "workspace.status";
    let completed = retargeted(&scenario("hostOnlyBuild"), leaf);
    let receipt = &completed["outcome"]["receipt"];
    let run_completed = run(&completed, leaf, &[]);
    assert_eq!(run_completed.output.status.code(), Some(0));
    assert!(run_completed.output.stderr.is_empty());
    let printed: Value = serde_json::from_slice(&run_completed.output.stdout).unwrap();
    assert_eq!(&clocked(&printed, receipt), receipt);
    assert!(String::from_utf8_lossy(&run_completed.output.stdout).contains("\n  \""));
    // The legacy `--json` is the bare receipt.
    let run_legacy = run(&completed, leaf, &["--json"]);
    assert_eq!(run_legacy.output.status.code(), Some(0));
    let printed: Value = serde_json::from_slice(&run_legacy.output.stdout).unwrap();
    assert_eq!(&clocked(&printed, receipt), receipt);

    let failed = retargeted(&scenario("hostScopeMismatch"), leaf);
    let run_failed = run(&failed, leaf, &[]);
    assert_eq!(run_failed.output.status.code(), Some(1));
    assert!(run_failed.output.stdout.is_empty());
    assert_eq!(
        String::from_utf8_lossy(&run_failed.output.stderr),
        format!(
            "arkdeck workspace: {}\n",
            failed["outcome"]["reason"].as_str().unwrap()
        )
    );
    let run_failed = run(&failed, leaf, &["--json"]);
    assert_eq!(run_failed.output.status.code(), Some(1));
    let printed: Value = serde_json::from_slice(&run_failed.output.stdout).unwrap();
    assert_eq!(
        clocked(&printed, &failed["outcome"]["receipt"]),
        failed["outcome"]["receipt"]
    );

    let paused = retargeted(&scenario("explicitTargetNotListed"), leaf);
    let run_paused = run(&paused, leaf, &[]);
    assert_eq!(run_paused.output.status.code(), Some(75));
    assert!(run_paused.output.stdout.is_empty());
    let action = &paused["outcome"]["action"];
    assert_eq!(
        labelled(&json!(String::from_utf8_lossy(&run_paused.output.stderr))),
        json!(format!(
            "human action required ({}): {}\nresume with: arkdeck agent resume --resume-token {}\n\
             arkdeck: paused for physical assistance\n",
            action["kind"].as_str().unwrap(),
            action["prompt"].as_str().unwrap(),
            action["resumeToken"].as_str().unwrap()
        ))
    );
    let run_paused = run(&paused, leaf, &["--json"]);
    assert_eq!(run_paused.output.status.code(), Some(75));
    assert_eq!(
        serde_json::from_slice::<Value>(&run_paused.output.stdout).unwrap(),
        json!({"error": {"code": "humanActionRequired",
            "message": "paused for physical assistance"}})
    );
}

/// `--capability` names a capability the Runtime already holds: its
/// reference is forwarded in the submitted request's authorization, as given.
#[test]
fn a_named_capability_is_forwarded_as_its_reference() {
    let leaf = "workspace.read";
    let mut scenario = retargeted(&scenario("hostOnlyBuild"), leaf);
    scenario["request"]["capabilityReference"] = json!("CAP-RT-EXAMPLE-G1");
    let run = run(&scenario, leaf, &["--output", "json"]);
    assert_eq!(run.output.status.code(), Some(0));
    let submitted: Value = serde_json::from_str(
        run.seen
            .sent
            .iter()
            .find(|frame| frame["method"] == "job.submit")
            .unwrap()["params"]["requestJson"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        submitted["authorization"],
        json!({"capabilityId": "CAP-RT-EXAMPLE-G1"})
    );
}

/// A leaf that changes a workspace or a device authorizes it only with what
/// the caller names: `workspace sign` of the main tree names a capability a
/// person had the Runtime issue, and it is forwarded as that reference; an
/// isolated copy's sign, and any leaf without `--capability`, submits no
/// authorization at all and leaves the decision to the Runtime. The CLI never
/// builds one.
#[test]
fn a_mutation_leaf_forwards_only_the_capability_it_is_given() {
    let submitted = |run: &Run| -> Value {
        serde_json::from_str(
            run.seen
                .sent
                .iter()
                .find(|frame| frame["method"] == "job.submit")
                .unwrap()["params"]["requestJson"]
                .as_str()
                .unwrap(),
        )
        .unwrap()
    };
    for (leaf, recorded) in [
        ("workspace.sign", "hostOnlyBuild"),
        ("input.tap", "explicitTargetConnected"),
    ] {
        let named = {
            let mut scenario = retargeted(&scenario(recorded), leaf);
            scenario["request"]["capabilityReference"] = json!("CAP-RT-MANUAL-G1");
            run(&scenario, leaf, &["--output", "json"])
        };
        assert_eq!(named.output.status.code(), Some(0), "{leaf}");
        assert_eq!(
            submitted(&named)["authorization"],
            json!({"capabilityId": "CAP-RT-MANUAL-G1"}),
            "{leaf}"
        );
        let unnamed = run(
            &retargeted(&scenario(recorded), leaf),
            leaf,
            &["--output", "json"],
        );
        assert_eq!(unnamed.output.status.code(), Some(0), "{leaf}");
        assert_eq!(submitted(&unnamed).get("authorization"), None, "{leaf}");
    }
}

/// Typed inputs are one readable JSON object, or the leaf is refused as a
/// usage error before anything is sent, in every output mode.
#[test]
fn unreadable_typed_inputs_are_refused_before_any_request() {
    let root = private_root();
    let socket = root.0.join("a.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
    listener.set_nonblocking(true).unwrap();
    let array = root.0.join("array.json");
    std::fs::write(&array, b"[1]").unwrap();
    let absent = root.0.join("absent.json");
    for path in [&array, &absent] {
        let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(["analyze", "trace", "--inputs-file"])
            .arg(path)
            .args(["--output", "json", "--socket"])
            .arg(&socket)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(64));
        assert!(output.stdout.is_empty());
        assert_eq!(
            String::from_utf8_lossy(&output.stderr),
            format!(
                "arkdeck analyze: cannot read typed inputs from {}\n",
                path.display()
            )
        );
    }
    assert!(listener.accept().is_err(), "nothing was sent");
}
