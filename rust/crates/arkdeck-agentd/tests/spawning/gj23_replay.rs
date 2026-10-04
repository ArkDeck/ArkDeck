//! GJ-2 (`debug.hap@1`) and GJ-3 (`deploy.native-library.app-owned@1`) end
//! to end on Windows (TASK-XPA-009): every exchange the Swift oracles
//! recorded (`rust/tests/fixtures/debug-hap`, 63; `deploy-native-library`,
//! 40), sent by the real signed `arkdeck.exe` to the signed test daemon
//! (`signed_daemon.rs`), which composes the production Windows development
//! root and the shared fake HDC's answers in process. Every answer, every
//! call the fake received, the Target document and everything the replay
//! leaves below the root must be Swift's, read as the hoststore replays read
//! them (`arkdeck-hoststore/tests/support/hdc_oracle.rs`): host paths in the
//! oracle's spelling, the plan digests and what they derive relabelled one to
//! one (rulings 48 and 61).
//!
//! The replay root is the oracle's, rebuilt (`support::debug_hap::rebuild`),
//! with its Job, Session owner and Sessions roots under the names a Windows
//! development root gives them (`jobs-state`, `session-state`, `sessions`)
//! while the daemon serves, and under the oracle's names again for the
//! comparison. The daemon reads the oracle's clock, proves its device
//! mutations against the replay's own Job state (where a development root
//! names the account's), and composes the code-sign helper the native oracle
//! recorded; each is an input of the test daemon alone (`signed_daemon.rs`).
//! Host tests only: nothing reaches a device or an installed Runtime.
use crate::signed_daemon::{self, SignedDaemon};
use crate::support::{self, debug_hap, document, hdc_oracle, legacy_plan_answer, oracle_fake};
use serde_json::{Value, json};
use std::fs;
use std::path::Path;

/// The fake's application state, which each oracle clears before every Job
/// it runs (`hdc_oracle::Owners::mode`).
const APPLICATION_STATE: [&str; 3] = ["device-installed", "device-running", "device-published"];

/// The oracle's root directories under the names the daemon's development
/// root gives them, in the order they are renamed.
const RENAMED: [(&str, &str); 3] = [
    ("store", "jobs-state"),
    ("session-owner", "session-state"),
    ("Sessions", "sessions"),
];

/// Renames each oracle directory below `root` to the daemon's name, or back.
fn rename(root: &Path, to_daemon: bool) {
    for (oracle, daemon) in RENAMED {
        let (from, to) = if to_daemon {
            (oracle, daemon)
        } else {
            (daemon, oracle)
        };
        fs::rename(root.join(from), root.join(to)).unwrap();
    }
}

/// `text` with the daemon's directory names below `root` spelled as the
/// oracle's, plainly and in JSON's escaping.
fn oracle_names(text: &str, root: &Path) -> String {
    let mut text = text.to_owned();
    for (oracle, daemon) in RENAMED {
        for (from, to) in [
            (root.join(daemon), root.join(oracle)),
            (root.join(daemon).join(""), root.join(oracle).join("")),
        ] {
            let (from, to) = (from.to_string_lossy(), to.to_string_lossy());
            let escaped = |path: &str| path.replace('\\', r"\\");
            for (from, to) in [
                (format!("{from}\\"), format!("{to}\\")),
                (format!("{from}\""), format!("{to}\"")),
                (
                    format!("{}\\\\", escaped(&from)),
                    format!("{}\\\\", escaped(&to)),
                ),
                (
                    format!("{}\"", escaped(&from)),
                    format!("{}\"", escaped(&to)),
                ),
            ] {
                text = text.replace(&from, &to);
            }
        }
    }
    text
}

/// The fake answers the next Job in `mode`, its application state cleared.
fn mode(root: &Path, mode: &str) {
    for state in APPLICATION_STATE {
        let _ = fs::remove_file(root.join(state));
    }
    set_mode(root, mode);
}

fn set_mode(root: &Path, mode: &str) {
    fs::write(root.join("hdc-mode"), format!("{mode}\n")).unwrap();
}

/// The Runtime's answer behind the CLI's envelope: the result, or the
/// Runtime's refusal (its wire code, words and details, without the method
/// and wire code the CLI adds).
fn wire(envelope: &Value) -> Value {
    if envelope["ok"] == true {
        return json!({"ok": true, "result": envelope["result"]});
    }
    let error = &envelope["error"];
    let mut details = error["details"].as_object().cloned().unwrap_or_default();
    let code = details
        .remove("wireCode")
        .unwrap_or_else(|| panic!("a refusal the Runtime did not give: {envelope}"));
    details.remove("method");
    let mut answer = json!({"code": code, "message": error["message"]});
    if !details.is_empty() {
        answer["details"] = Value::Object(details);
    }
    json!({"ok": false, "error": answer})
}

/// One recorded request through the real CLI: its arguments.
fn arguments(exchange: &Value, requests: &Path, labels: &debug_hap::HostLabels) -> Vec<String> {
    let (name, method) = (
        exchange["name"].as_str().unwrap(),
        exchange["method"].as_str().unwrap(),
    );
    let params = &exchange["params"];
    let text = |key: &str| params[key].as_str().unwrap().to_owned();
    let owned = |items: &[&str]| items.iter().map(|item| (*item).to_owned()).collect();
    match method {
        "job.plan" | "job.submit" => {
            let path = requests.join(format!("{name}.json"));
            fs::write(&path, text("requestJson")).unwrap();
            let verb = method.trim_start_matches("job.");
            vec![
                "job".into(),
                verb.into(),
                "--request-file".into(),
                path.to_str().unwrap().into(),
            ]
        }
        "job.run" | "job.result" | "job.evidence" => {
            let verb = method.trim_start_matches("job.");
            vec!["job".into(), verb.into(), "--job".into(), text("jobId")]
        }
        "artifact.list" => {
            assert_eq!(params["owner"]["kind"], "job", "{name}");
            vec![
                "artifact".into(),
                "list".into(),
                "--job".into(),
                params["owner"]["id"].as_str().unwrap().into(),
                "--page-size".into(),
                params["pageSize"].to_string(),
            ]
        }
        "capability.list" => owned(&["capability", "list"]),
        "capability.inspect" => vec![
            "capability".into(),
            "inspect".into(),
            "--capability".into(),
            labels.host(&text("capabilityId")),
        ],
        "cleanupDebt.list" => owned(&["cleanup-debt", "list"]),
        "cleanupDebt.continue" => {
            let mut arguments: Vec<String> = vec![
                "cleanup-debt".into(),
                "continue".into(),
                "--job".into(),
                text("jobId"),
            ];
            if let Some(path) = params["remotePath"].as_str() {
                arguments.extend(["--remote-path".into(), path.into()]);
            }
            if let Some(bundle) = params["bundleName"].as_str() {
                arguments.extend(["--bundle".into(), bundle.into()]);
            }
            arguments
        }
        other => panic!("{name}: the oracle sent {other}"),
    }
}

/// Every recorded exchange of the oracle `name` through the CLI and the
/// signed test daemon, answered and left as Swift answered and left it.
fn replay(name: &str, exchanges: usize, calls: usize) {
    let _turn = crate::turn();
    let scratch = support::fixture_fs::temporary_root().join(format!(
        "gj23-replay-{name}-{:x}",
        u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap())
    ));
    let Some((executable, pin)) = signed_daemon::signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let requests = scratch.join("requests");
    fs::create_dir_all(&requests).unwrap();
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture(name);
    let cases = document(&fixture, "cases.json");
    let provenance = document(&fixture, "provenance.json");
    let root = debug_hap::rebuild(&fixture);
    rename(&root, true);
    let mut variables = vec![
        (
            signed_daemon::CLOCK,
            format!(
                "{}|{}",
                provenance["nowUTC"].as_str().unwrap(),
                provenance["nowPreciseUTC"].as_str().unwrap()
            ),
        ),
        (
            signed_daemon::MUTATION_ROOT,
            root.join("jobs-state").to_str().unwrap().to_owned(),
        ),
    ];
    if cases.get("codeSignHelper").is_some() {
        variables.push((
            signed_daemon::HELPER,
            fixture.join("cases.json").to_str().unwrap().to_owned(),
        ));
    }
    let daemon = SignedDaemon::start_with(&executable, &pin, &root, &fixture, &root, &variables);

    let spelled = |bytes: &[u8]| -> Vec<u8> {
        let Ok(text) = String::from_utf8(bytes.to_vec()) else {
            return bytes.to_vec();
        };
        let text = oracle_names(&text, &root);
        let sessions = format!(
            "\"{}\"",
            root.join("Sessions").to_string_lossy().replace('\\', r"\\")
        );
        let foundation = if text.contains(r"\/") {
            r#""\/tmp\/arkdeck-hdc-oracle\/Sessions""#
        } else {
            r#""/tmp/arkdeck-hdc-oracle/Sessions""#
        };
        let text = text.replace(&sessions, foundation);
        let text = oracle_fake::oracle_spelling_json(&text, &root);
        oracle_fake::oracle_spelling(&text, &root)
            .replace("\"PLATFORM-WINDOWS@0.2.0\"", "\"PLATFORM-MACOS@0.2.0\"")
            .into_bytes()
    };
    let spelled_json = |value: &Value| -> Value {
        serde_json::from_slice(&spelled(&serde_json::to_vec(value).unwrap())).unwrap()
    };
    let mut labels = debug_hap::HostLabels::default();
    let swift_capabilities = document(&fixture, "store/capabilities/runtime-capabilities.json");
    let mut answers = Vec::new();
    for exchange in cases["exchanges"].as_array().unwrap() {
        let method = exchange["method"].as_str().unwrap();
        match (method, exchange["mode"].as_str()) {
            ("job.run", Some(recorded)) => mode(&root, recorded),
            ("cleanupDebt.continue" | "cleanupDebt.list", Some(recorded)) => {
                set_mode(&root, recorded)
            }
            _ => (),
        }
        let arguments = arguments(exchange, &requests, &labels);
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        let (_, envelope) = daemon.cli(&arguments);
        let mut actual = wire(&envelope);
        if method == "artifact.list" && actual["ok"] == true {
            // The pager's revision is its own; the oracle labels it.
            actual["result"]["snapshotRevision"] = json!("<snapshotRevision>");
        }
        if method == "job.submit"
            && let Ok(bytes) =
                fs::read(root.join("jobs-state/capabilities/runtime-capabilities.json"))
        {
            let ours: Value = serde_json::from_slice(&bytes).unwrap();
            labels.learn_keys(&ours, &swift_capabilities, &["capabilityID"]);
        }
        if method.starts_with("cleanupDebt.") {
            hdc_oracle::assert_conforms(method, &actual);
        }
        answers.push((
            exchange["name"].clone(),
            spelled_json(&legacy_plan_answer(actual)),
            exchange["answer"].clone(),
        ));
    }
    assert_eq!(answers.len(), exchanges, "every exchange");
    daemon.stop();
    rename(&root, false);
    // The agent execution owner every Windows development root composes
    // (`windows_lifecycle`) opened its empty store; the oracles' daemons
    // composed none, and no exchange here reaches it.
    let agents = root.join("agent-executions");
    let entries: Vec<String> = fs::read_dir(&agents)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(entries, ["snapshots"], "the agent execution owner's store");
    assert_eq!(fs::read_dir(agents.join("snapshots")).unwrap().count(), 0);
    fs::remove_dir_all(&agents).unwrap();

    // The fake received Swift's calls, in order.
    let swift = fs::read_to_string(fixture.join("hdc-invocations.log")).unwrap();
    assert_eq!(swift.lines().count(), calls);
    assert_eq!(
        String::from_utf8(spelled(
            &fs::read(root.join("hdc-invocations.log")).unwrap()
        ))
        .unwrap(),
        swift,
        "the fake's calls"
    );
    assert_eq!(
        fs::read(root.join("targets-state/targets.json")).unwrap(),
        fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        "the Target document"
    );
    let default_root = root.join("store");
    for (case, job) in cases["jobs"].as_object().unwrap() {
        let record: Value = serde_json::from_slice(
            &fs::read(
                default_root
                    .join("jobs")
                    .join(job.as_str().unwrap())
                    .join("job-record.json"),
            )
            .unwrap(),
        )
        .unwrap();
        let consumed = record["timeline"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|line| *line == "capability consumed before first mutation")
            .count();
        assert_eq!(consumed, 1, "{case}");
    }
    hdc_oracle::assert_relabelled(
        &fixture,
        &root,
        &default_root,
        &answers,
        &mut labels,
        true,
        spelled,
    );
    let _ = fs::remove_dir_all(&scratch);
}

#[test]
fn the_real_cli_runs_every_swift_debug_hap_through_the_signed_test_daemon() {
    replay("debug-hap", 63, 108);
}

#[test]
fn the_real_cli_runs_every_swift_native_deployment_through_the_signed_test_daemon() {
    replay("deploy-native-library", 40, 225);
}
