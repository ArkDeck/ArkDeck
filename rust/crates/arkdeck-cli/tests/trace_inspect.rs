//! `arkdeck trace inspect` as Swift's handler serves it (`RuntimeCLI.runTrace`):
//! the exact Job-owned Trace Artifact, the sensitive grant and a bounded
//! inspection time are judged before anything is sent; one `trace.inspect`
//! follows; its answer is checked as Swift's `RuntimeTraceInspectionProjection`
//! checks it and emitted as the Runtime gave it.
//!
//! The oracle (`rust/tests/fixtures/trace-inspect`, recorded by
//! `CLITraceInspectOracleContractTests`) holds Swift's decisions. The fake
//! Runtime serves the frames Swift's daemon recorded
//! (`Fixtures/ControlFrames/trace.inspect.jsonl`). The Rust daemon refuses
//! every inspection (`operationUnavailable`), so the successful path has not
//! run against a real daemon.
use arkdeck_cli::{
    CliError, MACHINE_QUALITY_SCOPES, inspection_projection, inspection_request, legacy_refusal,
    parse,
};
use arkdeck_client::ClientError;
use arkdeck_contract::WireError;
use serde_json::{Map, Value, json};
use std::path::Path;
use std::process::Command;

fn oracle(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/trace-inspect")
        .join(name);
    serde_json::from_slice(
        &std::fs::read(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display())),
    )
    .unwrap()
}

fn text(value: &Value) -> &str {
    value.as_str().unwrap()
}

/// The engine versions carrying a format character (Unicode Cf), which
/// Foundation's `controlCharacters` holds and this CLI's check knows only on
/// macOS, where Swift's CLI runs.
const FORMAT_CHARACTER_CASES: [&str; 9] = [
    "engineVersionSoftHyphen",
    "engineVersionArabicNumberSign",
    "engineVersionZeroWidthSpace",
    "engineVersionLeftToRightMark",
    "engineVersionWordJoiner",
    "engineVersionByteOrderMark",
    "engineVersionInterlinearAnchor",
    "engineVersionLanguageTag",
    "engineVersionTagLatinA",
];

#[test]
fn each_answer_is_judged_as_swifts_projection_judges_it() {
    let cases = oracle("projections.json");
    let cases = cases.as_array().unwrap();
    assert!(cases.len() > 100, "{} cases", cases.len());
    let (mut accepted, mut refused) = (0, 0);
    for case in cases {
        let name = text(&case["name"]);
        let decided = inspection_projection(&case["value"]);
        if cfg!(not(target_os = "macos")) && FORMAT_CHARACTER_CASES.contains(&name) {
            assert_eq!(case["accepted"], false, "{name}");
            assert!(decided.is_some(), "{name}");
            continue;
        }
        assert_eq!(decided.is_some(), case["accepted"] == true, "{name}");
        match decided {
            Some((owner, artifact)) => {
                assert_eq!(owner, case["owner"], "{name}");
                assert_eq!(artifact, text(&case["artifactId"]), "{name}");
                accepted += 1;
            }
            None => refused += 1,
        }
    }
    assert!(
        accepted >= 10 && refused >= 80,
        "{accepted} accepted, {refused} refused"
    );
}

#[test]
fn a_quality_issue_names_only_swifts_scopes() {
    assert_eq!(
        oracle("scopes.json"),
        json!(MACHINE_QUALITY_SCOPES.as_slice())
    );
}

#[test]
fn each_refusal_maps_as_swift_maps_it() {
    let cases = oracle("failures.json");
    let cases = cases.as_array().unwrap();
    assert!(cases.len() >= 50);
    for case in cases {
        let wire = text(&case["wireCode"]);
        let error = CliError::from_client(
            ClientError::Remote(WireError {
                code: wire.to_owned(),
                message: format!("the Runtime refused {wire}"),
                details: Some(case["details"].as_object().unwrap().clone()),
            }),
            "trace.inspect",
        );
        assert_eq!(
            (
                error.code,
                error.message.as_str(),
                Value::Object(error.details)
            ),
            (
                text(&case["code"]),
                text(&case["message"]),
                case["mappedDetails"].clone()
            ),
            "{wire} with {}",
            case["evidence"]
        );
    }
}

/// The fields this CLI's parser reads from the handler's options.
fn fields(options: &[String]) -> Map<String, Value> {
    let mut fields = Map::new();
    let mut index = 0;
    while index < options.len() {
        let key = match options[index].as_str() {
            "--allow-sensitive" => {
                fields.insert("allowSensitive".into(), json!(true));
                index += 1;
                continue;
            }
            "--job" => "jobId",
            "--artifact" => "artifactId",
            "--timeout" => "timeout",
            other => panic!("an option the oracle does not use: {other}"),
        };
        fields.insert(key.into(), json!(options[index + 1]));
        index += 2;
    }
    fields
}

/// Swift's handler decisions, replayed on this CLI's handler for every argv,
/// then through this CLI where Swift's registry lets the argv reach the
/// handler. An argv its registry refuses is refused by this parser too, in the
/// registry's words, as the parse-refusal replay holds. No Runtime answers:
/// the endpoint names nothing.
#[test]
fn the_handler_judges_each_argv_before_anything_is_sent() {
    let absent = std::env::temp_dir().join("arkdeck-trace-inspect-no-daemon.sock");
    let mut skipped = Vec::new();
    for case in oracle("argv.json").as_array().unwrap() {
        let name = text(&case["name"]);
        let options: Vec<String> = case["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| text(value).to_owned())
            .collect();
        // The handler: Swift's order, words and details.
        match (
            text(&case["outcome"]),
            inspection_request(&fields(&options)),
        ) {
            ("requested", Ok(_)) => {}
            ("refused", Err(error)) => assert_eq!(
                (error.code, error.message.as_str(), json!(error.details)),
                (
                    text(&case["code"]),
                    text(&case["message"]),
                    case["details"].clone()
                ),
                "{name}"
            ),
            (outcome, decided) => panic!("{name}: Swift {outcome}, here {decided:?}"),
        }
        let mut argv: Vec<String> = vec!["trace".into(), "inspect".into()];
        argv.extend(options);
        // Whether Swift's registry lets the argv reach its handler.
        let mut probe = argv.clone();
        probe.push("--json".into());
        let reaches_the_handler = legacy_refusal(&probe);
        if let Err(error) = parse(&argv) {
            assert!(!reaches_the_handler, "{name}: {}", error.message);
            assert_eq!(error.code, "invalidOption", "{name}: {}", error.message);
            skipped.push(name.to_owned());
            continue;
        }
        assert!(reaches_the_handler, "{name}: Swift's registry refuses it");
        let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(&argv)
            .args(["--output", "json"])
            .env("ARKDECK_ENDPOINT", &absent)
            .output()
            .unwrap();
        let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
        let error = &envelope["error"];
        match text(&case["outcome"]) {
            // The request left for a Runtime that is not there.
            "requested" => {
                assert_eq!(
                    error["details"]["method"], "trace.inspect",
                    "{name}: {envelope}"
                );
            }
            _ => {
                assert_eq!(error["code"], case["code"], "{name}");
                assert_eq!(error["message"], case["message"], "{name}");
                let details = if error["details"].is_null() {
                    json!({})
                } else {
                    error["details"].clone()
                };
                assert_eq!(details, case["details"], "{name}");
                assert_eq!(
                    envelope["meta"]["controlProtocolVersion"], "1.0.0",
                    "{name}: a handler's refusal carries its session's protocol"
                );
            }
        }
    }
    assert_eq!(
        skipped,
        [
            "withoutAllowSensitive",
            "timeout-600001ms",
            "timeout-11m",
            "timeout-0ms",
            "timeout-2h",
            "timeout-soon",
            "timeout-05s",
            "jobColonAndTimeout11m",
            "jobImportIdentityAndTimeout11m",
        ],
        "the argv Swift's registry refuses before its handler"
    );
}

// The fake Runtime this leaf is driven against is a Unix socket.
#[cfg(target_os = "macos")]
mod support;

#[cfg(target_os = "macos")]
mod runtime {
    use super::support;
    use arkdeck_cli::legacy_document;
    use serde_json::{Value, json};

    /// Swift's daemon's recorded frames: a timed-out inspection, an answer,
    /// and the refusal of a daemon without an inspector.
    fn frames() -> Vec<Value> {
        include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/trace.inspect.jsonl"
        )
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
    }

    fn answered() -> Value {
        frames()
            .into_iter()
            .find(|frame| frame["ok"] == true)
            .unwrap()
    }

    fn argv(params: &Value) -> Vec<String> {
        vec![
            "trace".into(),
            "inspect".into(),
            "--job".into(),
            params["owner"]["id"].as_str().unwrap().into(),
            "--artifact".into(),
            params["artifactId"].as_str().unwrap().into(),
            "--allow-sensitive".into(),
            "--timeout".into(),
            format!("{}ms", params["timeoutMs"]),
        ]
    }

    fn run(argv: &[String], params: &Value, response: Value) -> (std::process::Output, Value) {
        let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
        support::run(
            &argv,
            vec![("trace.inspect".to_owned(), params.clone(), response)],
        )
    }

    #[test]
    fn the_inspection_is_requested_once_and_emitted_as_the_runtime_gave_it() {
        let frame = answered();
        let params = &frame["params"];
        let reply = json!({"ok": true, "result": frame["result"]});
        let (output, envelope) = run(&argv(params), params, reply.clone());
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        assert_eq!(envelope["command"], "trace.inspect");
        assert_eq!(envelope["result"], frame["result"]);
        // The legacy `--json` rendering is the same answer, as Swift writes it.
        let mut legacy = argv(params);
        legacy.push("--json".into());
        let (output, _) = run(&legacy, params, reply);
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(output.stdout, legacy_document(&frame["result"]));
    }

    #[test]
    fn a_daemon_without_an_inspector_refuses_with_its_owners_proof() {
        // The Rust daemon's answer, which Swift's daemon without an inspector
        // also gives: before it reads a parameter.
        let refusal = frames()
            .into_iter()
            .find(|frame| frame["error"]["code"] == "operationUnavailable")
            .unwrap();
        let params = json!({"owner": {"kind": "job", "id": "job-trace-inspect"},
            "artifactId": "ART-9c914630ca801dc5e25b24667d40e4fe", "allowSensitive": true,
            "timeoutMs": 120000});
        let defaults: Vec<String> = [
            "trace",
            "inspect",
            "--job",
            "job-trace-inspect",
            "--artifact",
            "ART-9c914630ca801dc5e25b24667d40e4fe",
            "--allow-sensitive",
        ]
        .map(String::from)
        .to_vec();
        let (output, envelope) = run(
            &defaults,
            &params,
            json!({"ok": false, "error": refusal["error"]}),
        );
        assert_eq!(output.status.code(), Some(69), "{envelope}");
        assert_eq!(envelope["error"]["code"], "operationUnavailable");
        assert_eq!(
            envelope["error"]["message"],
            "Trace inspection is unavailable"
        );
        assert_eq!(
            envelope["error"]["details"],
            json!({"phase": "traceInspectionOwner", "newDispatchCount": 0,
                "deviceEvidenceCreated": false, "wireCode": "operationUnavailable",
                "method": "trace.inspect"})
        );
        // The inspection that timed out is the Runtime's failure, as it said.
        let timed_out = frames()
            .into_iter()
            .find(|frame| frame["error"]["code"] == "operationFailed")
            .unwrap();
        let (output, envelope) = run(
            &argv(&timed_out["params"]),
            &timed_out["params"],
            json!({"ok": false, "error": timed_out["error"]}),
        );
        assert_eq!(output.status.code(), Some(1), "{envelope}");
        assert_eq!(envelope["error"]["code"], "operationFailed");
        assert_eq!(
            envelope["error"]["message"],
            "Trace inspection timed out and was drained"
        );
    }

    #[test]
    fn an_answer_of_another_source_or_off_its_shape_is_unreadable() {
        let frame = answered();
        // The Runtime answered for an Artifact other than the one asked for.
        let mut params = frame["params"].clone();
        params["artifactId"] = json!("ART-other");
        let (output, envelope) = run(
            &argv(&params),
            &params,
            json!({"ok": true, "result": frame["result"]}),
        );
        assert_eq!(output.status.code(), Some(2), "{envelope}");
        assert_eq!(envelope["error"]["code"], "recordUnreadable");
        assert_eq!(
            envelope["error"]["message"],
            "Trace inspection belongs to another source"
        );
        // A durable inspection is not one this leaf reads.
        let mut result = frame["result"].clone();
        result["storageMode"] = json!("durable");
        let params = &frame["params"];
        let (output, envelope) = run(&argv(params), params, json!({"ok": true, "result": result}));
        assert_eq!(output.status.code(), Some(2), "{envelope}");
        assert_eq!(envelope["error"]["code"], "recordUnreadable");
        assert_eq!(
            envelope["error"]["message"],
            "Runtime returned an invalid Trace inspection"
        );
    }
}
