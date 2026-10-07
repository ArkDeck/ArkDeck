//! GJ-2 (`debug.hap@1`) and GJ-3 (`deploy.native-library.app-owned@1`) end
//! to end on Windows (TASK-XPA-009): every exchange the Swift oracles
//! recorded (`rust/tests/fixtures/debug-hap-catalog-e4-v1`, 63; the versioned current
//! `deploy-native-library-observed-v1`, 40), sent by the real signed `arkdeck.exe` to the signed test daemon
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
use crate::gj1_device_leaves;
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
pub(crate) fn wire(envelope: &Value) -> Value {
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
            // Both spellings of the leaf: a remote path's debt through
            // `recovery cleanup continue`, a bundle's through `cleanup-debt
            // continue`.
            let mut arguments: Vec<String> = if params["remotePath"].is_string() {
                owned(&["recovery", "cleanup", "continue"])
            } else {
                owned(&["cleanup-debt", "continue"])
            };
            arguments.extend(["--job".into(), text("jobId")]);
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
    let current_native = name == hdc_oracle::native_current::NAME;
    let current_hap = name == hdc_oracle::hap_current::NAME;
    if current_hap {
        hdc_oracle::hap_current::assert_source(&fixture);
    }
    if current_native {
        hdc_oracle::native_current::assert_source(&fixture);
    }
    let native_import = current_native.then(|| hdc_oracle::native_current::prepare_import(&root));
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
        // Validate every additive native value before comparing the frozen
        // pre-proof oracle's original bytes, just as the hoststore replay does.
        let native;
        let bytes = if name == "deploy-native-library" {
            native = hdc_oracle::native_readback::historical_bytes(bytes);
            native.as_slice()
        } else {
            bytes
        };
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
    let mut labels = if current_native || current_hap {
        debug_hap::HostLabels::portable()
    } else {
        debug_hap::HostLabels::default()
    };
    let swift_capabilities = document(&fixture, "store/capabilities/runtime-capabilities.json");
    let mut answers = Vec::new();
    let mut publication_proofs = Vec::new();
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
        if current_native || method.starts_with("cleanupDebt.") {
            hdc_oracle::assert_conforms(method, &actual);
        }
        if current_native && method == "job.run" && exchange.get("mode").is_some() {
            let job = exchange["params"]["jobId"].as_str().unwrap();
            let record: Value = serde_json::from_slice(
                &fs::read(
                    root.join("jobs-state/jobs")
                        .join(job)
                        .join("job-record.json"),
                )
                .unwrap(),
            )
            .unwrap();
            let session = record["sessionPublicationRecord"]["sessionID"]
                .as_str()
                .unwrap();
            let (_, shown) = daemon.cli(&["session", "show", "--session", session]);
            assert_eq!(shown["ok"], true);
            let import = native_import.as_ref().unwrap();
            let (_, inspection) = daemon.cli(&[
                "artifact",
                "import",
                "inspect",
                "--import",
                import["importId"].as_str().unwrap(),
            ]);
            assert_eq!(inspection["ok"], true);
            let digest = arkdeck_contract::sha256_hex(&fs::read(root.join("hdc")).unwrap());
            publication_proofs.push(hdc_oracle::native_current::proof(
                &root,
                job,
                shown["result"].clone(),
                inspection["result"].clone(),
                import,
                &digest,
            ));
        }
        if current_hap && exchange["method"] == "job.plan" {
            hdc_oracle::hap_current::assert_plan(&actual, exchange, &root);
        }
        let actual = if current_native || current_hap {
            actual
        } else {
            legacy_plan_answer(actual)
        };
        answers.push((
            exchange["name"].clone(),
            spelled_json(&actual),
            exchange["answer"].clone(),
        ));
    }
    assert_eq!(answers.len(), exchanges, "every exchange");
    if current_native {
        hdc_oracle::native_current::assert_original_calls(
            &fs::read_to_string(root.join("hdc-invocations.log")).unwrap(),
            &root,
        );
        answers.extend(hdc_oracle::native_current::publication_answers(
            &fixture,
            &publication_proofs,
            &spelled,
        ));
    }
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
    replay(hdc_oracle::hap_current::NAME, 63, 108);
    gj1_device_leaves::assert_windows_status(&["cleanupDebt.continue"], "implemented");
}

#[test]
fn the_real_cli_runs_every_swift_native_deployment_through_the_signed_test_daemon() {
    replay(hdc_oracle::native_current::NAME, 40, 240);
}

/// The oracle's connect key, which the synthetic census's board serial
/// equals (the fixture's adopted Target).
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
/// The Target the oracles adopted.
const TARGET: &str = "TGT-3ba3f5f43b92";

/// `text` with every Job identity replaced by one label, so a Job this run
/// minted compares with the oracle's.
fn unlabelled_jobs(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find("job-") {
        out.push_str(&rest[..at]);
        let tail = &rest[at + 4..];
        let hex = tail
            .bytes()
            .take_while(|byte| byte.is_ascii_hexdigit())
            .count();
        if hex == 32 {
            out.push_str("job-<id>");
            rest = &tail[32..];
        } else {
            out.push_str("job-");
            rest = tail;
        }
    }
    out.push_str(rest);
    out
}

/// The oracle's domain leaf (`debug hap`, `debug native deploy`) run by the
/// real signed CLI against the signed test daemon over the oracle's root,
/// with the board the oracle's Target names in the synthetic census: the
/// leaf observes the board, submits and runs the operation's Job with the
/// inputs of the oracle's first case, reads its evidence and Artifacts, and
/// completes; the fake HDC must have received, after the leaf's observation
/// reads, exactly the calls the oracle's first Job made (its Job identity
/// aside, which this run mints).
fn domain_leaf(fixture_name: &str, leaf: &[&str], command: &str, operation: &str) {
    let _turn = crate::turn();
    let scratch = support::fixture_fs::temporary_root().join(format!(
        "gj23-leaf-{fixture_name}-{:x}",
        u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap())
    ));
    let Some((executable, pin)) = signed_daemon::signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture(fixture_name);
    let cases = document(&fixture, "cases.json");
    let provenance = document(&fixture, "provenance.json");
    let exchanges = cases["exchanges"].as_array().unwrap();
    let submit = exchanges
        .iter()
        .find(|exchange| exchange["method"] == "job.submit")
        .unwrap();
    let request: Value =
        serde_json::from_str(submit["params"]["requestJson"].as_str().unwrap()).unwrap();
    assert_eq!(request["target"]["targetId"], TARGET);
    let run = exchanges
        .iter()
        .find(|exchange| exchange["method"] == "job.run")
        .unwrap();
    let root = debug_hap::rebuild(&fixture);
    rename(&root, true);
    mode(&root, run["mode"].as_str().unwrap());
    let inputs = scratch.join("inputs.json");
    fs::write(&inputs, serde_json::to_vec(&request["inputs"]).unwrap()).unwrap();
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
        (signed_daemon::BOARD, KEY.to_owned()),
    ];
    if cases.get("codeSignHelper").is_some() {
        variables.push((
            signed_daemon::HELPER,
            fixture.join("cases.json").to_str().unwrap().to_owned(),
        ));
    }
    let daemon = SignedDaemon::start_with(&executable, &pin, &root, &fixture, &root, &variables);
    let mut arguments: Vec<&str> = leaf.to_vec();
    arguments.extend([
        "--target",
        TARGET,
        "--inputs-file",
        inputs.to_str().unwrap(),
    ]);
    let (status, envelope) = daemon.cli(&arguments);
    daemon.stop();
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["ok"], true, "{envelope}");
    assert_eq!(envelope["command"], command, "{envelope}");
    let receipt = &envelope["result"];
    assert_eq!(receipt["operationReference"], operation, "{receipt}");
    assert_eq!(receipt["outcomeUnknown"], false, "{receipt}");
    // The evidence observation as the versioned oracle's first Job result
    // carries it. Current Native deployments have their own typed prefix.
    let result = exchanges
        .iter()
        .find(|exchange| exchange["method"] == "job.result")
        .unwrap();
    let observation = &result["answer"]["result"]["evidence"]["observation"];
    if observation.is_null() {
        assert!(receipt["evidenceObservation"].is_null(), "{receipt}");
    } else {
        assert_eq!(observation["targetId"], TARGET);
        assert_eq!(
            receipt["evidenceObservation"]["targetId"], TARGET,
            "{receipt}"
        );
    }
    assert!(
        receipt["artifacts"]
            .as_array()
            .unwrap()
            .iter()
            .all(|artifact| artifact["bytesVerified"] == true),
        "{receipt}"
    );

    // The oracle's first Job: all calls up to the next Job's observation
    // or the first call naming another Job.
    let swift = fs::read_to_string(fixture.join("hdc-invocations.log")).unwrap();
    let swift: Vec<&str> = swift.lines().collect();
    let first_job = result["answer"]["result"]["evidence"]["jobId"]
        .as_str()
        .unwrap();
    let next = swift[1..]
        .iter()
        .position(|line| {
            line.starts_with("list\u{1f}targets\u{1f}-v\u{1f}")
                || (line.contains("job-") && !line.contains(first_job))
        })
        .map_or(swift.len(), |at| at + 1);
    let job: Vec<String> = swift[..next]
        .iter()
        .map(|line| unlabelled_jobs(line))
        .collect();
    let ours = String::from_utf8(fs::read(root.join("hdc-invocations.log")).unwrap()).unwrap();
    let ours = oracle_fake::oracle_spelling(&oracle_names(&ours, &root), &root);
    let ours: Vec<String> = ours.lines().map(unlabelled_jobs).collect();
    assert!(ours.len() >= job.len(), "{ours:#?}");
    let observations = ours.len() - job.len();
    assert!(
        ours[..observations]
            .iter()
            .all(|call| call.starts_with("list\u{1f}targets\u{1f}-v\u{1f}")),
        "the leaf's observation reads: {ours:#?}"
    );
    assert_eq!(ours[observations..], job[..], "the oracle's Job calls");
    rename(&root, false);
    let _ = fs::remove_dir_all(&scratch);
}

#[test]
fn the_real_cli_debug_hap_leaf_runs_the_swift_oracle_s_job() {
    domain_leaf(
        hdc_oracle::hap_current::NAME,
        &["debug", "hap"],
        "debug.hap",
        "debug.hap@1",
    );
    gj1_device_leaves::assert_windows_status(&["debug.hap@1"], "implemented");
}

#[test]
fn the_real_cli_debug_native_deploy_leaf_runs_the_swift_oracle_s_job() {
    domain_leaf(
        hdc_oracle::native_current::NAME,
        &["debug", "native", "deploy"],
        "debug.native.deploy",
        "deploy.native-library.app-owned@1",
    );
    gj1_device_leaves::assert_windows_status(&["deploy.native-library.app-owned@1"], "implemented");
}
