use arkdeck_cli::{parse, validate_read_only_response};
use serde_json::{Value, json};
const STATUS: &str = include_str!(
    "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.status.jsonl"
);
const DESCRIBE: &str = include_str!(
    "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/operation.describe.jsonl"
);
const JOB_LIST: &str = include_str!(
    "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.list.jsonl"
);
const JOB_SHOW: &str = include_str!(
    "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.show.jsonl"
);
const TIMELINE: &str = include_str!(
    "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.timeline.jsonl"
);
const EVIDENCE: &str = include_str!(
    "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.evidence.jsonl"
);
fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|s| (*s).to_owned()).collect()
}
fn sample(corpus: &str) -> Value {
    corpus
        .lines()
        .map(|s| serde_json::from_str::<Value>(s).unwrap())
        .find(|v| v["ok"] == true)
        .unwrap()
}
fn status_invocation(value: &Value) -> arkdeck_cli::Invocation {
    parse(&args(&[
        "job",
        "status",
        "--job",
        value["jobId"].as_str().unwrap(),
    ]))
    .unwrap()
}
#[test]
fn published_argv_fixtures_replay() {
    for corpus in [
        include_str!("../../../tests/fixtures/current-cli-argv/operation.example.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/operation.describe.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/job.status.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/job.list.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/job.show.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/job.evidence.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/job.timeline.json"),
    ] {
        let doc: Value = serde_json::from_str(corpus).unwrap();
        for case in doc["cases"].as_array().unwrap() {
            let argv = case["argv"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap().to_owned())
                .collect::<Vec<_>>();
            let result = parse(&argv);
            if case["name"] == "macosCompatibilityOption" && !cfg!(target_os = "macos") {
                assert_eq!(result.unwrap_err().code, "unsupportedOnPlatform");
            } else if case["expected"]["outcome"] == "failure" {
                assert_eq!(result.unwrap_err().code, case["expected"]["code"], "{case}");
            } else {
                let result = result.unwrap();
                assert_eq!(result.command, doc["command"]);
                assert_eq!(result.help, case["expected"]["outcome"] == "leafHelp");
            }
        }
    }
}

fn job_recording_args(frame: &Value) -> Vec<String> {
    let method = frame["method"].as_str().unwrap();
    let mut argv = args(&["job", method.strip_prefix("job.").unwrap()]);
    if let Some(params) = frame["params"].as_object() {
        for (key, value) in params {
            let flag = match key.as_str() {
                "jobId" => "--job",
                "pageSize" => "--page-size",
                "cursor" => "--cursor",
                "includeCurrent" => "--include-current",
                "includeTimeline" => "--include-timeline",
                "order" => "--order",
                "state" => "--state",
                "operation" => "--operation",
                "target" => "--target",
                "thread" => "--thread",
                _ => panic!("unexpected recorded parameter {key}"),
            };
            if value == &json!(false) {
                continue;
            }
            argv.push(flag.into());
            if value != &json!(true) {
                argv.push(
                    value
                        .as_str()
                        .map(str::to_owned)
                        .unwrap_or_else(|| value.to_string()),
                );
            }
        }
    }
    argv
}

fn compiled_view_supports_job_filters() -> bool {
    let supported = arkdeck_contract::validate_method_value("job.list", "request", &json!({
        "state":"succeeded", "operation":"observe.device@1", "target":"TGT-fixture", "thread":"thread-a"
    })).is_ok();
    let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
    if inputs["kind"] == "candidate" {
        assert!(
            supported,
            "candidate must include the actual Swift filter request contract"
        );
    }
    supported
}

#[test]
fn current_recorded_job_lists_and_details_are_returned_verbatim() {
    let mut counts = [0, 0];
    let supports_filters = compiled_view_supports_job_filters();
    for (index, corpus) in [JOB_LIST, JOB_SHOW].into_iter().enumerate() {
        for frame in corpus
            .lines()
            .map(|s| serde_json::from_str::<Value>(s).unwrap())
            .filter(|v| v["ok"] == true)
        {
            let invocation = parse(&job_recording_args(&frame)).unwrap();
            assert_eq!(invocation.timeout_ms, Some(30_000));
            if frame["method"] == "job.list"
                && !supports_filters
                && ["state", "operation", "target", "thread"]
                    .iter()
                    .any(|key| frame["params"].get(*key).is_some())
            {
                assert!(
                    arkdeck_contract::validate_method_value(
                        "job.list",
                        "request",
                        &Value::Object(invocation.params.unwrap())
                    )
                    .is_err(),
                    "the published schema cannot send a candidate-only filter"
                );
                continue;
            }
            let result =
                arkdeck_cli::project_read_only_response(&invocation, frame["result"].clone());
            assert!(
                result.is_ok(),
                "{} {:?}: {result:?}",
                frame["method"],
                frame["params"]
            );
            assert_eq!(result.unwrap(), frame["result"]);
            counts[index] += 1;
        }
    }
    // Preserve every existing producer frame while allowing new current
    // producer recordings to extend the exact contract corpus.
    assert!(counts[0] >= 10);
    assert_eq!(counts[1], 13);
}

#[test]
fn job_read_options_are_typed_and_leaf_specific() {
    let invocation = parse(&args(&[
        "job",
        "list",
        "--page-size",
        "12",
        "--include-current",
        "--include-timeline",
        "--order",
        "createdAtAscJobIdAsc",
        "--cursor",
        "opaque",
        "--timeout",
        "2s",
    ]))
    .unwrap();
    assert_eq!(invocation.timeout_ms, Some(2000));
    assert_eq!(
        invocation.params.unwrap(),
        serde_json::from_value(json!({"pageSize":12,"includeCurrent":true,
        "includeTimeline":true,"order":"createdAtAscJobIdAsc","cursor":"opaque"}))
        .unwrap()
    );
    assert_eq!(
        parse(&args(&["job", "list"]))
            .unwrap()
            .params
            .unwrap()
            .len(),
        0
    );
    for argv in [
        vec!["job", "list", "--page-size", "01"],
        vec!["job", "list", "--page-size", "0"],
        vec!["job", "list", "--page-size", "1001"],
        vec!["job", "list", "--order", "oldestFirst"],
        vec!["job", "list", "--job", "id"],
        vec!["job", "show", "--job", "id", "--include-current"],
        vec!["job", "show", "--job", "bad:id"],
        vec!["job", "list", "--timeout", "25h"],
        vec!["job", "list", "--state", "inventedState"],
        vec!["job", "list", "--operation", "bad\nfilter"],
        vec!["job", "show", "--job", "id", "--thread", "thread"],
    ] {
        assert!(parse(&args(&argv)).is_err(), "{argv:?}");
    }
    let invocation = parse(&args(&[
        "job",
        "list",
        "--state",
        "queued",
        "--operation",
        "observe.device@1",
        "--target",
        "TGT-test",
        "--thread",
        "thread-test",
    ]))
    .unwrap();
    assert_eq!(
        invocation.params.unwrap(),
        serde_json::from_value(json!({"state":"queued",
        "operation":"observe.device@1", "target":"TGT-test", "thread":"thread-test"}))
        .unwrap()
    );
    let oversized = "x".repeat(257);
    assert!(parse(&args(&["job", "list", "--target", &oversized])).is_err());
}

#[test]
fn job_show_refuses_changed_references_and_incomplete_timeline() {
    let frame = sample(JOB_SHOW);
    let invocation = parse(&job_recording_args(&frame)).unwrap();
    for (pointer, bad) in [
        ("/job/jobId", json!("different")),
        ("/events/jobId", json!("different")),
        ("/evidence/method", json!("job.run")),
        ("/catalogDigest", json!("bad")),
        ("/timeline", Value::Null),
        (
            "/timeline",
            json!({"kind":"snapshotPages","jobId":"different","method":"job.timeline"}),
        ),
    ] {
        let mut value = frame["result"].clone();
        *value.pointer_mut(pointer).unwrap() = bad;
        assert_eq!(
            validate_read_only_response(&invocation, &value)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
    }
}

#[test]
fn job_list_refuses_partial_or_cross_snapshot_pages_and_orders_dates_as_instants() {
    let frame = sample(JOB_LIST);
    let invocation = parse(&job_recording_args(&frame)).unwrap();
    for (pointer, bad) in [
        ("/order", json!("createdAtAscJobIdAsc")),
        ("/snapshotRevision", json!("invalid")),
        (
            "/snapshotRevision",
            json!("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
        ),
        ("/nextCursor", Value::Null),
        ("/items", json!([])),
        ("/items/0/nextAction/owner/id", json!("other")),
        ("/items/0/current", Value::Null),
        ("/items/0/schemaVersion", json!("arkdeck.job-status/1")),
    ] {
        let mut value = frame["result"].clone();
        *value.pointer_mut(pointer).unwrap() = bad;
        assert_eq!(
            validate_read_only_response(&invocation, &value)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
    }
    let mut page = frame["result"].clone();
    page["hasMore"] = json!(false);
    page["nextCursor"] = Value::Null;
    let mut first = page["items"][0].clone();
    first["jobId"] = json!("job-a");
    first["nextAction"]["owner"]["id"] = json!("job-a");
    first["nextAction"]["resource"]["id"] = json!("job-a");
    let mut second = first.clone();
    second["jobId"] = json!("job-b");
    second["nextAction"]["owner"]["id"] = json!("job-b");
    second["nextAction"]["resource"]["id"] = json!("job-b");
    // Same instant in different textual offsets: Job identity breaks the tie.
    first["createdAtUtc"] = json!("2026-09-11T08:00:00+08:00");
    second["createdAtUtc"] = json!("2026-09-11T00:00:00Z");
    page["items"] = json!([first, second]);
    let invocation = parse(&args(&["job", "list"])).unwrap();
    validate_read_only_response(&invocation, &page).unwrap();
    page["items"].as_array_mut().unwrap().reverse();
    assert!(validate_read_only_response(&invocation, &page).is_err());
    page["items"].as_array_mut().unwrap().reverse();
    page["items"][0]["createdAtUtc"] = json!("2026-09-11T00:00:00.125Z");
    validate_read_only_response(&invocation, &page).unwrap();
    page["items"][1]["createdAtUtc"] = json!("2026-09-11T00:00:00.250Z");
    assert!(validate_read_only_response(&invocation, &page).is_err());
    let first = page["items"][0].clone();
    page["items"] = json!([first, first]);
    assert!(validate_read_only_response(&invocation, &page).is_err());
    let mut short = frame["result"].clone();
    short["items"][0]["timeline"] = Value::Null;
    let invocation = parse(&args(&["job", "list", "--include-timeline"])).unwrap();
    assert!(validate_read_only_response(&invocation, &short).is_err());
}
#[test]
fn published_results_are_consumed_without_inventing_facts() {
    for corpus in [STATUS, DESCRIBE] {
        for frame in corpus
            .lines()
            .map(|s| serde_json::from_str::<Value>(s).unwrap())
            .filter(|v| v["ok"] == true)
        {
            let v = &frame["result"];
            let invocation = if frame["method"] == "job.status" {
                status_invocation(v)
            } else {
                parse(&args(&[
                    "operation",
                    "describe",
                    "--operation",
                    frame["params"]["reference"].as_str().unwrap(),
                ]))
                .unwrap()
            };
            validate_read_only_response(&invocation, v).unwrap();
        }
    }
}
#[test]
fn bad_identity_timeout_and_cross_leaf_options_are_refused() {
    for argv in [
        vec!["job", "status", "--job", "bad:id"],
        vec!["job", "status", "--job", "id", "--timeout", "25h"],
        vec!["job", "status", "--job", "id", "--timeout", "01s"],
        vec!["operation", "describe", "--operation", "x", "--job", "id"],
    ] {
        assert!(parse(&args(&argv)).is_err());
    }
    let v = parse(&args(&[
        "job",
        "status",
        "--job",
        "id",
        "--timeout",
        "500ms",
    ]))
    .unwrap();
    assert_eq!(v.timeout_ms, Some(500));
    assert_eq!(
        v.params.unwrap(),
        serde_json::from_value(json!({"jobId":"id"})).unwrap()
    );
}
#[test]
fn unknown_outcomes_stay_query_results_and_false_next_actions_fail_closed() {
    let mut v = sample(STATUS)["result"].clone();
    let invocation = status_invocation(&v);
    v["outcomeUnknown"] = json!(true);
    v["outcome"] = json!("outcomeUnknown");
    v["nextAction"]["kind"] = json!("reconcile");
    v["nextAction"]["reasonCode"] = json!("recovery.outcomeUnknown");
    v["nextAction"]
        .as_object_mut()
        .unwrap()
        .remove("retryAfter");
    validate_read_only_response(&invocation, &v).unwrap();
    for (pointer, value) in [
        ("/nextAction/kind", json!("readResult")),
        ("/nextAction/owner/id", json!("other-job")),
        ("/sessionPublication/state", json!("published")),
        ("/sessionPublication/reasonCode", json!("guessed")),
        ("/createdAtUtc", json!("2026-02-30T00:00:00Z")),
        ("/outcome", json!("succeeded")),
    ] {
        let mut bad = v.clone();
        *bad.pointer_mut(pointer).unwrap() = value;
        assert_eq!(
            validate_read_only_response(&invocation, &bad)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
    }
    let mut described = sample(DESCRIBE);
    let reference = described["params"]["reference"]
        .as_str()
        .unwrap()
        .to_owned();
    let invocation = parse(&args(&["operation", "describe", "--operation", &reference])).unwrap();
    described["result"]["reference"] = json!("different@1");
    assert!(validate_read_only_response(&invocation, &described["result"]).is_err());
}
#[cfg(target_os = "macos")]
mod endpoint {
    use super::*;
    use arkdeck_contract::{
        CATALOG_DIGEST, CONTRACT_IDENTITY, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, METHODS,
        PROTOCOL_VERSION, encode_frame,
    };
    use arkdeck_platform::{LocalEndpoint, LocalListener, read_frame};
    use std::{
        io::{BufReader, Write},
        os::unix::fs::DirBuilderExt,
    };
    fn run(argv: &[&str], response: Value) -> (std::process::Output, Vec<Value>) {
        run_delayed(argv, response, 0)
    }
    fn run_delayed(
        argv: &[&str],
        response: Value,
        delay_ms: u64,
    ) -> (std::process::Output, Vec<Value>) {
        let suffix = arkdeck_platform::random_bytes::<8>()
            .unwrap()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        let root = std::path::PathBuf::from(format!("/private/tmp/cli-read-{suffix}"));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&root)
            .unwrap();
        let path = root.join("socket");
        let mut listener = LocalListener::bind(&LocalEndpoint::new(&path)).unwrap();
        let server = std::thread::spawn(move || {
            let mut stream = BufReader::new(listener.accept().unwrap());
            stream
                .get_ref()
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
            let mut requests = Vec::new();
            for result in [
                json!({"id":"health","ok":true,"result":{"status":"ok","protocolVersion":PROTOCOL_VERSION,"contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,"providers":[],"publishedMethods":METHODS}}),
                response,
            ] {
                let frame = match read_frame(&mut stream, MAX_REQUEST_BYTES) {
                    Ok(frame) => frame,
                    Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => break,
                    Err(error) => panic!("cannot read test request: {error}"),
                };
                requests.push(serde_json::from_slice::<Value>(&frame).unwrap());
                std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                if stream
                    .get_mut()
                    .write_all(&encode_frame(&result, MAX_RESPONSE_BYTES).unwrap())
                    .is_err()
                {
                    break;
                }
            }
            let mut extra = Vec::new();
            std::io::Read::read_to_end(&mut stream, &mut extra).unwrap();
            assert!(extra.is_empty(), "CLI replayed an exchange after timeout");
            requests
        });
        let output = std::process::Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(argv)
            .args([
                "--output",
                "json",
                "--control-request-id",
                "cli-read-test",
                "--socket",
            ])
            .arg(&path)
            .output()
            .unwrap();
        let requests = server.join().unwrap();
        std::fs::remove_dir(&root).unwrap();
        (output, requests)
    }
    #[test]
    fn timeline_invalid_cursor_requires_current_schema_and_zero_dispatch_proof() {
        let supported = arkdeck_contract::validate_method_value(
            "job.timeline",
            "errorCode",
            &json!("invalidCursor"),
        )
        .is_ok();
        let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
        if inputs["kind"] == "candidate" {
            assert!(
                supported,
                "current producer invalidCursor must be represented"
            );
        }
        for count in [0, 1] {
            let (output, requests) = run(
                &[
                    "job",
                    "timeline",
                    "--job",
                    "job-a",
                    "--cursor",
                    "malformed-token",
                ],
                json!({
                    "id":"cli-read-test", "ok":false, "error":{"code":"invalidCursor", "message":"cursor is invalid, belongs to another query or its snapshot was reclaimed", "details":{"newDispatchCount":count,"phase":"preAdmission"}}
                }),
            );
            assert!(!output.status.success());
            assert_eq!(requests.len(), 2);
            let doc: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(doc["ok"], false);
            assert!(doc.get("result").is_none());
            assert_eq!(
                doc["error"]["code"],
                if !supported {
                    "protocolMalformed"
                } else if count == 0 {
                    "invalidCursor"
                } else {
                    "internalError"
                }
            );
        }
    }

    #[test]
    fn timeline_processes_keep_one_page_and_reject_invalid_cursor_without_replay() {
        for frame in TIMELINE
            .lines()
            .map(|s| serde_json::from_str::<Value>(s).unwrap())
        {
            if frame["ok"] != true && frame["error"]["code"] != "invalidCursor" {
                continue;
            }
            let argv = job_recording_args(&frame);
            if let Err(error) = parse(&argv) {
                assert_eq!(frame["error"]["code"], "invalidCursor");
                assert_eq!(error.code, "invalidCursor");
                continue;
            }
            let argv: Vec<_> = argv.iter().map(String::as_str).collect();
            let mut response = frame.clone();
            for key in ["method", "params", "protocolVersion"] {
                response.as_object_mut().unwrap().remove(key);
            }
            response["id"] = json!("cli-read-test");
            let (output, requests) = run(&argv, response);
            let doc: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(requests.len(), 2);
            assert_eq!(requests[1]["method"], "job.timeline");
            assert_eq!(requests[1]["params"], frame["params"]);
            if frame["ok"] == true {
                assert!(output.status.success(), "{doc}");
                assert_eq!(doc["ok"], true);
                assert_eq!(doc["result"], frame["result"]);
            } else {
                assert!(!output.status.success());
                assert_eq!(doc["ok"], false);
                assert!(doc.get("result").is_none());
                let supported = arkdeck_contract::validate_method_value(
                    "job.timeline",
                    "errorCode",
                    &json!("invalidCursor"),
                )
                .is_ok();
                assert_eq!(
                    doc["error"]["code"],
                    if supported {
                        "invalidCursor"
                    } else {
                        "protocolMalformed"
                    }
                );
            }
        }
        let mut page = sample(TIMELINE)["result"].clone();
        page["items"] =
            json!([{"entryIndex":"0","partIndex":"0","lastPart":true,"text":"界".repeat(21846)}]);
        let (output, requests) = run(
            &["job", "timeline", "--job", "job-a"],
            json!({"id":"cli-read-test","ok":true,"result":page}),
        );
        assert_eq!(output.status.code(), Some(2));
        assert_eq!(requests.len(), 2);
        let doc: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(doc["error"]["code"], "recordUnreadable");
        assert!(doc.get("result").is_none());
    }

    #[test]
    fn evidence_attention_keeps_successful_result_and_never_replays() {
        for status in [
            "verified",
            "resultNotReady",
            "artifactIntegrityFailed",
            "futureReason",
        ] {
            let mut snapshot = EVIDENCE
                .lines()
                .map(|s| serde_json::from_str::<Value>(s).unwrap())
                .find(|v| v["result"]["status"] == "verified")
                .unwrap()["result"]
                .clone();
            snapshot["status"] = json!(status);
            snapshot["blockers"] = if status == "verified" {
                json!([])
            } else {
                json!(["reason"])
            };
            let id = snapshot["jobId"].as_str().unwrap();
            let (output, requests) = run(
                &["job", "evidence", "--job", id],
                json!({"id":"cli-read-test","ok":true,"result":snapshot}),
            );
            assert_eq!(
                output.status.code(),
                Some(if status == "verified" {
                    0
                } else if status == "resultNotReady" {
                    75
                } else {
                    2
                })
            );
            let result: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(result["ok"], true);
            assert_eq!(result["result"], snapshot);
            assert_eq!(requests.len(), 2);
            assert_eq!(requests[1]["method"], "job.evidence");
            assert_eq!(requests[1]["params"], json!({"jobId":id}));
        }
        let snapshot = sample(EVIDENCE)["result"].clone();
        let (output, requests) = run(
            &["job", "evidence", "--job", "wrong-job"],
            json!({"id":"cli-read-test","ok":true,"result":snapshot}),
        );
        assert_eq!(output.status.code(), Some(2));
        let result: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(result["ok"], false);
        assert!(result.get("result").is_none());
        assert_eq!(requests.len(), 2);
    }

    #[test]
    fn evidence_timeout_is_shared_by_health_and_query_and_emits_no_snapshot_or_replay() {
        let snapshot = sample(EVIDENCE)["result"].clone();
        let id = snapshot["jobId"].as_str().unwrap();
        let (out, requests) = run_delayed(
            &["job", "evidence", "--job", id, "--timeout", "2s"],
            json!({"id":"cli-read-test","ok":true,"result":snapshot}),
            1200,
        );
        assert_eq!(out.status.code(), Some(75));
        assert!(out.stderr.is_empty());
        let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(doc["ok"], false);
        assert_eq!(doc["command"], "job.evidence");
        assert_eq!(doc["error"]["code"], "clientTimeout");
        assert!(doc.get("result").is_none());
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0]["method"], "health");
        assert_eq!(requests[1]["method"], "job.evidence");
    }
    #[test]
    fn job_timeout_is_shared_by_health_and_status_and_emits_no_snapshot_or_replay() {
        let snapshot = sample(STATUS)["result"].clone();
        let id = snapshot["jobId"].as_str().unwrap();
        let (out, requests) = run_delayed(
            &["job", "status", "--job", id, "--timeout", "2s"],
            json!({"id":"cli-read-test","ok":true,"result":snapshot}),
            1200,
        );
        assert_eq!(out.status.code(), Some(75));
        assert!(out.stderr.is_empty());
        let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(doc["ok"], false);
        assert_eq!(doc["command"], "job.status");
        assert_eq!(doc["error"]["code"], "clientTimeout");
        assert!(doc.get("result").is_none());
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0]["method"], "health");
        assert_eq!(requests[1]["method"], "job.status");
    }
    #[test]
    fn executable_queries_same_connection_and_preserves_snapshot_and_refusal() {
        let snapshot = sample(STATUS)["result"].clone();
        let id = snapshot["jobId"].as_str().unwrap();
        let (out, requests) = run(
            &["job", "status", "--job", id],
            json!({"id":"cli-read-test","ok":true,"result":snapshot}),
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stdout)
        );
        assert!(out.stderr.is_empty());
        let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(doc["result"], snapshot);
        assert_eq!(requests[0]["method"], "health");
        assert_eq!(requests[1]["method"], "job.status");
        assert_eq!(requests[1]["params"], json!({"jobId":id}));
        assert_eq!(requests.len(), 2);
        let described = sample(DESCRIBE);
        let reference = described["params"]["reference"].as_str().unwrap();
        let (out, requests) = run(
            &["operation", "describe", "--operation", reference],
            json!({"id":"cli-read-test","ok":true,"result":described["result"]}),
        );
        assert!(out.status.success());
        let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(doc["result"], described["result"]);
        assert_eq!(requests[1]["method"], "operation.describe");
        let mut malformed = snapshot.clone();
        malformed["nextAction"]["owner"]["id"] = json!("other");
        let (out, _) = run(
            &["job", "status", "--job", id],
            json!({"id":"cli-read-test","ok":true,"result":malformed}),
        );
        assert_eq!(out.status.code(), Some(2));
        let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(doc["ok"], false);
        assert!(doc.get("result").is_none());
        assert_eq!(doc["error"]["code"], "recordUnreadable");
        let (out, requests) = run(
            &["operation", "describe", "--operation", "missing@1"],
            json!({"id":"cli-read-test","ok":false,"error":{"code":"unknownMethod","message":"backend is unavailable"}}),
        );
        assert_eq!(out.status.code(), Some(69));
        let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(doc["ok"], false);
        assert_eq!(doc["error"]["code"], "controlMethodUnavailable");
        assert_eq!(requests[1]["params"], json!({"reference":"missing@1"}));
        assert_eq!(requests.len(), 2);
    }

    #[test]
    fn job_list_and_show_processes_query_once_preserve_facts_and_never_follow_references() {
        for corpus in [JOB_LIST, JOB_SHOW] {
            let frame = sample(corpus);
            let argv = job_recording_args(&frame);
            let argv: Vec<_> = argv.iter().map(String::as_str).collect();
            let (out, requests) = run(
                &argv,
                json!({"id":"cli-read-test","ok":true,"result":frame["result"]}),
            );
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stdout)
            );
            assert!(out.stderr.is_empty());
            let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
            assert_eq!(doc["command"], frame["method"]);
            assert_eq!(doc["result"], frame["result"]);
            assert_eq!(requests.len(), 2);
            assert_eq!(requests[0]["method"], "health");
            assert_eq!(requests[1]["method"], frame["method"]);
            assert_eq!(
                requests[1]["params"],
                Value::Object(parse(&job_recording_args(&frame)).unwrap().params.unwrap())
            );
            assert!(requests[1]["params"].get("timeout").is_none());

            let mut uncertain = frame["result"].clone();
            let status = if frame["method"] == "job.list" {
                &mut uncertain["items"][0]
            } else {
                &mut uncertain["job"]
            };
            status["outcomeUnknown"] = json!(true);
            status["outcome"] = json!("outcomeUnknown");
            status["nextAction"]["kind"] = json!("reconcile");
            status["nextAction"]["reasonCode"] = json!("recovery.outcomeUnknown");
            status["nextAction"]
                .as_object_mut()
                .unwrap()
                .remove("retryAfter");
            let (out, requests) = run(
                &argv,
                json!({"id":"cli-read-test","ok":true,"result":uncertain}),
            );
            assert!(
                out.status.success(),
                "a read query must preserve attention facts"
            );
            let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
            assert_eq!(doc["result"], uncertain);
            assert_eq!(requests.len(), 2);

            let mut invalid = frame["result"].clone();
            if frame["method"] == "job.list" {
                invalid["items"][0]["nextAction"]["owner"]["id"] = json!("other");
            } else {
                invalid["evidence"]["jobId"] = json!("other");
            }
            let (out, requests) = run(
                &argv,
                json!({"id":"cli-read-test","ok":true,"result":invalid}),
            );
            assert_eq!(out.status.code(), Some(2));
            let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
            assert_eq!(doc["error"]["code"], "recordUnreadable");
            assert!(doc.get("result").is_none());
            assert_eq!(requests.len(), 2);
        }
        for (argv, remote, local) in [
            (
                vec!["job", "show", "--job", "missing"],
                "notFound",
                "resourceNotFound",
            ),
            (
                vec!["job", "list", "--cursor", "stale"],
                "invalidCursor",
                "invalidCursor",
            ),
        ] {
            let mut refusal = json!({"id":"cli-read-test","ok":false,"error":{"code":remote,"message":"read refused"}});
            if remote == "invalidCursor" {
                refusal["error"]["details"] = json!({"phase":"preAdmission","newDispatchCount":0});
            }
            let (out, requests) = run(&argv, refusal);
            assert!(!out.status.success());
            let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
            assert_eq!(doc["error"]["code"], local);
            assert!(doc.get("result").is_none());
            assert_eq!(requests.len(), 2);
        }
        let (out, requests) = run(
            &["job", "list", "--cursor", "stale"],
            json!({"id":"cli-read-test","ok":false,"error":{"code":"invalidCursor","message":"no refusal evidence"}}),
        );
        let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(doc["error"]["code"], "internalError");
        assert!(!out.status.success());
        assert_eq!(requests.len(), 2);
    }

    #[test]
    fn recorded_filtered_pages_and_long_timeline_references_stay_single_queries() {
        if !compiled_view_supports_job_filters() {
            use std::os::unix::fs::PermissionsExt;
            let token = arkdeck_platform::random_bytes::<8>()
                .unwrap()
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>();
            let root = std::path::PathBuf::from(format!("/private/tmp/cli-unpublished-{token}"));
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&root)
                .unwrap();
            let path = root.join("socket");
            let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
            listener.set_nonblocking(true).unwrap();
            let out = std::process::Command::new(env!("CARGO_BIN_EXE_arkdeck"))
                .args([
                    "job",
                    "list",
                    "--state",
                    "succeeded",
                    "--operation",
                    "observe.device@1",
                    "--target",
                    "TGT-fixture",
                    "--thread",
                    "thread-a",
                    "--output",
                    "json",
                    "--socket",
                ])
                .arg(&path)
                .output()
                .unwrap();
            assert!(!out.status.success());
            let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
            assert_eq!(doc["error"]["code"], "protocolMalformed");
            assert!(doc.get("result").is_none());
            assert!(
                matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
                "unsupported filters must not connect or send a frame"
            );
            drop(listener);
            std::fs::remove_file(&path).unwrap();
            std::fs::remove_dir(&root).unwrap();
            return;
        }
        let mut checked = 0;
        for frame in JOB_LIST
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .filter(|frame| {
                frame["ok"] == true
                    && ((["state", "operation", "target", "thread"]
                        .iter()
                        .all(|key| frame["params"].get(*key).is_some()))
                        || frame["params"]["includeTimeline"] == true
                            && frame["params"].get("thread").is_some())
            })
        {
            let owned = job_recording_args(&frame);
            let argv: Vec<_> = owned.iter().map(String::as_str).collect();
            let (out, requests) = run(
                &argv,
                json!({"id":"cli-read-test","ok":true,"result":frame["result"]}),
            );
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stdout)
            );
            let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
            assert_eq!(doc["result"], frame["result"]);
            assert_eq!(requests.len(), 2);
            assert_eq!(requests[1]["method"], "job.list");
            assert_eq!(requests[1]["params"], frame["params"]);
            let mut wrong = frame["result"].clone();
            wrong["items"][0]["threadId"] = json!("different-thread");
            let (out, requests) = run(
                &argv,
                json!({"id":"cli-read-test","ok":true,"result":wrong}),
            );
            assert_eq!(out.status.code(), Some(2));
            let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
            assert_eq!(doc["error"]["code"], "recordUnreadable");
            assert!(doc.get("result").is_none());
            assert_eq!(requests.len(), 2);
            checked += 1;
        }
        assert_eq!(
            checked, 3,
            "requires the actual Swift filtered/long-timeline corpus"
        );
    }
}

#[test]
fn examples_consume_the_runtime_descriptor_without_local_substitution() {
    for row in DESCRIBE
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
    {
        if row["ok"] != true {
            continue;
        }
        let descriptor = row["result"].clone();
        let invocation = parse(&args(&[
            "operation",
            "example",
            "--operation",
            descriptor["reference"].as_str().unwrap(),
        ]))
        .unwrap();
        assert_eq!(invocation.method, "operation.describe");
        assert_eq!(
            arkdeck_cli::project_read_only_response(&invocation, descriptor.clone()).unwrap(),
            descriptor["exampleRequest"]
        );
        let mut wrong = descriptor;
        wrong["reference"] = json!("wrong@1");
        assert_eq!(
            arkdeck_cli::project_read_only_response(&invocation, wrong)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
    }
}

#[test]
fn evidence_consumes_all_recorded_results_and_rejects_inconsistent_verification() {
    let frames: Vec<Value> = EVIDENCE
        .lines()
        .map(|s| serde_json::from_str::<Value>(s).unwrap())
        .filter(|v| v["ok"] == true)
        .collect();
    assert_eq!(frames.len(), 15);
    for frame in frames {
        let invocation = parse(&job_recording_args(&frame)).unwrap();
        assert_eq!(invocation.timeout_ms, Some(30_000));
        arkdeck_cli::validate_read_only_request(&invocation).unwrap();
        assert_eq!(
            arkdeck_cli::project_read_only_response(&invocation, frame["result"].clone()).unwrap(),
            frame["result"]
        );
        let mut unknown = frame["result"].clone();
        unknown["status"] = json!("futureReason");
        unknown["blockers"] = json!(["futureBlocker"]);
        validate_read_only_response(&invocation, &unknown).unwrap();
        for (key, value) in [
            ("jobId", json!("different-job")),
            ("status", json!("verified")),
            ("blockers", json!([])),
            ("catalogDigest", json!("F".repeat(64))),
            ("missingRequiredArtifacts", json!([""])),
        ] {
            let mut bad = unknown.clone();
            bad[key] = value;
            assert_eq!(
                validate_read_only_response(&invocation, &bad)
                    .unwrap_err()
                    .code,
                "recordUnreadable",
                "{key}"
            );
        }
    }
    for argv in [
        vec!["job", "evidence"],
        vec!["job", "evidence", "--job", "bad:id"],
        vec!["job", "evidence", "--job", "id", "--timeout", "0s"],
        vec!["job", "evidence", "--job", "id", "--include-timeline"],
    ] {
        assert!(parse(&args(&argv)).is_err());
    }
}

#[test]
fn timeline_recorded_pages_are_verbatim_and_options_are_bounded() {
    let mut count = 0;
    for frame in TIMELINE
        .lines()
        .map(|s| serde_json::from_str::<Value>(s).unwrap())
        .filter(|v| v["ok"] == true)
    {
        let invocation = parse(&job_recording_args(&frame)).unwrap();
        assert_eq!(invocation.timeout_ms, Some(30_000));
        arkdeck_cli::validate_read_only_request(&invocation).unwrap();
        assert_eq!(
            arkdeck_cli::project_read_only_response(&invocation, frame["result"].clone()).unwrap(),
            frame["result"]
        );
        count += 1;
    }
    assert!(count > 0);
    let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
    if inputs["kind"] == "candidate" {
        assert!(
            count >= 7,
            "candidate must include the real segmented and empty pages"
        );
    }
    let parsed = parse(&args(&[
        "job",
        "timeline",
        "--job",
        "job-a",
        "--page-size",
        "12",
        "--cursor",
        "opaque",
        "--timeout",
        "2s",
    ]))
    .unwrap();
    assert_eq!(parsed.timeout_ms, Some(2000));
    assert_eq!(
        Value::Object(parsed.params.unwrap()),
        json!({"jobId":"job-a","pageSize":12,"cursor":"opaque"})
    );
    for extra in [
        ["--page-size", "0"],
        ["--page-size", "1001"],
        ["--page-size", "01"],
        ["--cursor", ""],
        ["--order", "entryIndexAscPartIndexAsc"],
        ["--timeout", "25h"],
    ] {
        let mut argv = args(&["job", "timeline", "--job", "job-a"]);
        argv.extend(args(&extra));
        assert!(parse(&argv).is_err());
    }
}

#[test]
fn timeline_segments_are_canonical_contiguous_and_bounded_in_utf8_bytes() {
    let frame = sample(TIMELINE);
    let invocation = parse(&job_recording_args(&frame)).unwrap();
    let mut page = frame["result"].clone();
    // Starting mid-entry is valid for a continuation and no zero-origin is invented.
    page["items"] = json!([
        {"entryIndex":"7","partIndex":"2","text":"续页","lastPart":false},
        {"entryIndex":"7","partIndex":"3","text":"尾","lastPart":true},
        {"entryIndex":"8","partIndex":"0","text":"下一项","lastPart":true}
    ]);
    page["hasMore"] = json!(false);
    page["nextCursor"] = Value::Null;
    let mut invocation = invocation;
    invocation.params.as_mut().unwrap().remove("pageSize");
    validate_read_only_response(&invocation, &page).unwrap();
    for (row, key, bad_value) in [
        (0, "entryIndex", json!("-1")),
        (0, "entryIndex", json!("9223372036854775808")),
        (0, "partIndex", json!("02")),
        (0, "partIndex", json!("+2")),
        (1, "partIndex", json!("4")),
        (1, "entryIndex", json!("8")),
        (0, "lastPart", json!(true)),
        (1, "lastPart", json!(false)),
        (2, "entryIndex", json!("9")),
        (2, "partIndex", json!("1")),
        (0, "text", json!("界".repeat(21846))),
    ] {
        let mut bad = page.clone();
        bad["items"][row][key] = bad_value;
        assert_eq!(
            validate_read_only_response(&invocation, &bad)
                .unwrap_err()
                .code,
            "recordUnreadable",
            "row {row} {key}"
        );
    }
    for (key, val) in [
        ("snapshotRevision", json!("invalid")),
        ("order", json!("wrong")),
        ("hasMore", json!(true)),
        ("nextCursor", json!("unexpected")),
    ] {
        let mut bad = page.clone();
        bad[key] = val;
        assert!(validate_read_only_response(&invocation, &bad).is_err());
    }
    page["items"] = json!([{"entryIndex":"9223372036854775807","partIndex":"9223372036854775807","text":"x".repeat(65536),"lastPart":false}]);
    validate_read_only_response(&invocation, &page).unwrap();
    let row = page["items"][0].clone();
    page["items"].as_array_mut().unwrap().push(row);
    assert!(validate_read_only_response(&invocation, &page).is_err());
}
