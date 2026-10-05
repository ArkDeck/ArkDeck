//! GJ-5's workspace continuation end to end on Windows (TASK-XPA-011): the
//! real signed `arkdeck.exe` continues a completed Job through `workspace
//! continuation inspect|submit|run` against the signed test daemon
//! (`signed_daemon.rs`), over the shared fake HDC answering as the
//! `observe-device` oracle's driver, and the `workspace-continuation`
//! oracle's decisions (`rust/tests/fixtures/workspace-continuation`).
//!
//! The source Job is a completed `target observe` (`observe.device@1`, a
//! device-bound read-only Job, the oracle's `deviceReadOnly` source). The
//! Runtime's `health` lists the providers it composes, as Swift's daemon
//! listed them and the oracle's health records (`hdc`, `workspace`); the
//! continuation draft requires the source Job's provider there. Each answer
//! is the one Swift's draft makes of the Runtime's own reads (`Draft`, which
//! `arkdeck-cli/tests/workspace_continuation.rs` replays against the oracle):
//! the draft, the fresh request the Runtime records for the continuation
//! identity (shaped as the oracle's `continue-001` request), the submit's
//! acceptance without a run, the run that dispatches exactly the oracle Job's
//! calls, a second run that answers the settled Job and sends nothing, and an
//! identity Swift refuses, refused before anything is submitted. Host tests
//! only: no device, `hdc` or board is reached.
use crate::signed_daemon::{SignedDaemon, fixtures, signed_copy, temporary};
use arkdeck_cli::{Draft, request_json};
use arkdeck_platform::HostDirectory;
use serde_json::{Value, json};
use std::path::Path;

/// The oracles' connect key, which the board's serial equals.
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
/// The Target the oracles adopted.
const TARGET: &str = "TGT-3ba3f5f43b92";
/// The oracle's continuation identity.
const IDENTITY: &str = "continue-001";

/// The calls the fake (or the oracle's driver) logged in `root`.
fn calls(root: &Path) -> Vec<String> {
    std::fs::read_to_string(root.join("hdc-invocations.log"))
        .unwrap_or_default()
        .lines()
        .map(|line| line.trim_end_matches('\u{1f}').replace('\u{1f}', " "))
        .collect()
}

/// A JSON object's keys.
fn keys(value: &Value) -> Vec<String> {
    value
        .as_object()
        .unwrap_or_else(|| panic!("an object: {value}"))
        .keys()
        .cloned()
        .collect()
}

fn state_files(root: &Path) -> std::collections::BTreeMap<std::path::PathBuf, Vec<u8>> {
    let mut files = std::collections::BTreeMap::new();
    for child in std::fs::read_dir(root).unwrap() {
        let path = child.unwrap().path();
        if path.is_dir() {
            files.extend(state_files(&path));
        } else {
            files.insert(path.clone(), std::fs::read(path).unwrap());
        }
    }
    files
}

#[test]
fn a_completed_job_is_continued_over_the_signed_test_daemon() {
    let _turn = crate::turn();
    let scratch = temporary("gj5-continuation");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let oracle: Value = serde_json::from_slice(
        &std::fs::read(fixtures("workspace-continuation").join("cases.json")).unwrap(),
    )
    .unwrap();
    let fixture = fixtures("observe-device");
    let (root, fake_root) = (scratch.join("state"), scratch.join("fake"));
    HostDirectory::open_or_create_private(&root.join("targets-state")).unwrap();
    HostDirectory::open(&root.join("targets-state"))
        .unwrap()
        .create_document(
            "targets.json",
            &std::fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        )
        .unwrap();
    std::fs::create_dir_all(&fake_root).unwrap();
    let daemon =
        SignedDaemon::start_with_board(&executable, &pin, &root, &fixture, &fake_root, KEY);

    // The Runtime publishes the providers it composes, as the oracle's
    // Swift daemon did. Health is a side-effect-free inventory of assembled
    // ports; doctor separately computes fresh operation availability.
    let before_health = state_files(&root);
    let before_health_calls = calls(&fake_root);
    let (status, health) = daemon.cli(&["runtime", "health"]);
    assert_eq!(status, Some(0), "{health}");
    assert_eq!(
        state_files(&root),
        before_health,
        "health wrote owner state"
    );
    assert_eq!(
        calls(&fake_root),
        before_health_calls,
        "health dispatched HDC"
    );
    let health = health["result"].clone();
    // Registration does not claim an available executor or target admission.
    // The inventory also includes the assembled analyzer and ArkForge ports.
    let providers: Vec<&str> = health["providers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|provider| provider.as_str().unwrap())
        .collect();
    let mut sorted = providers.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(providers, sorted, "{health}");
    assert_eq!(providers, ["analyzer", "arkforge", "hdc", "workspace"]);
    for provider in oracle["health"]["providers"].as_array().unwrap() {
        assert!(
            providers.contains(&provider.as_str().unwrap()),
            "{provider}: {health}"
        );
    }

    // The source: a completed device-bound read.
    let (status, observed) = daemon.cli(&["target", "observe", "--target", TARGET]);
    assert_eq!(status, Some(0), "{observed}");
    let source = observed["result"]["jobID"].as_str().unwrap().to_owned();
    let (_, shown) = daemon.cli(&["job", "show", "--job", &source]);
    let (_, target) = daemon.cli(&["target", "show", "--target", TARGET]);
    let draft = Draft::prepare(&source, &shown["result"], &health, Some(&target["result"]))
        .unwrap_or_else(|error| panic!("the source is continuable: {}", error.message));
    let expected_request = draft.request(IDENTITY).unwrap();
    let recorded_request: Value = serde_json::from_str(
        oracle["requests"]
            .as_array()
            .unwrap()
            .iter()
            .find(|case| {
                case["source"] == "deviceReadOnly" && case["continuationRequestId"] == IDENTITY
            })
            .unwrap()["outcome"]["value"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    let projection = |dispatched: bool| -> Value {
        oracle["projections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|case| case["source"] == "deviceReadOnly" && case["dispatched"] == dispatched)
            .unwrap()["value"]
            .clone()
    };
    let continuation = |verb: &str, identity: &str| {
        daemon.cli(&[
            "workspace",
            "continuation",
            verb,
            "--source-job",
            &source,
            "--continuation-request-id",
            identity,
        ])
    };

    // inspect: Swift's draft of the Runtime's reads, nothing sent.
    let before = calls(&fake_root).len();
    let (status, inspected) = daemon.cli(&[
        "workspace",
        "continuation",
        "inspect",
        "--source-job",
        &source,
    ]);
    assert_eq!(status, Some(0), "{inspected}");
    assert_eq!(
        inspected["result"],
        draft.projection(None, None, None, false, None),
        "{inspected}"
    );
    assert_eq!(inspected["result"]["eligible"], true, "{inspected}");
    assert_eq!(inspected["result"]["effectiveEffect"], "readOnly");

    // An identity Swift refuses: refused before anything is submitted.
    let (status, refused) = continuation("submit", "sample");
    assert_eq!(status, Some(65), "{refused}");
    assert_eq!(refused["error"]["code"], "invalidInput", "{refused}");
    assert_eq!(calls(&fake_root).len(), before, "nothing was sent");

    // submit: accepted, not run. The Job holds Swift's fresh request, shaped
    // as the oracle's `continue-001` request.
    let (status, submitted) = continuation("submit", IDENTITY);
    assert_eq!(status, Some(0), "{submitted}");
    assert_eq!(
        submitted["command"], "workspace.continuation.submit",
        "{submitted}"
    );
    let result = &submitted["result"];
    let job = result["jobId"].as_str().unwrap().to_owned();
    assert_ne!(job, source);
    assert_eq!(result["dispatched"], false, "{submitted}");
    assert_eq!(result["deduplicated"], false, "{submitted}");
    assert_eq!(keys(result), keys(&projection(false)), "{submitted}");
    assert_eq!(
        *result,
        draft.projection(
            Some(IDENTITY),
            Some(&job),
            Some(false),
            false,
            Some(result["job"].clone())
        ),
        "{submitted}"
    );
    assert_eq!(calls(&fake_root).len(), before, "a submit runs nothing");
    let (_, accepted) = daemon.cli(&["job", "show", "--job", &job]);
    let request = &accepted["result"]["request"];
    assert_eq!(
        serde_json::to_string(request).unwrap(),
        request_json(&expected_request),
        "the Runtime records Swift's request"
    );
    assert_eq!(keys(request), keys(&recorded_request), "{request}");
    for key in [
        "documentType",
        "schemaVersion",
        "operation",
        "inputs",
        "requestedOutputs",
        "idempotencyKey",
        "requestId",
    ] {
        assert_eq!(request[key], recorded_request[key], "{key}: {request}");
    }
    assert_eq!(
        request["clientContext"]["clientName"],
        recorded_request["clientContext"]["clientName"]
    );
    assert_eq!(
        request["clientContext"]["provenance"]["arkdeck.continuedFromJob"],
        source.as_str()
    );

    // run: the accepted Job is run once, sending exactly the oracle Job's
    // calls, and read back succeeded.
    let (status, ran) = continuation("run", IDENTITY);
    assert_eq!(status, Some(0), "{ran}");
    assert_eq!(ran["command"], "workspace.continuation.run", "{ran}");
    let result = &ran["result"];
    assert_eq!(result["jobId"], job.as_str(), "{ran}");
    assert_eq!(result["dispatched"], true, "{ran}");
    assert_eq!(result["deduplicated"], true, "{ran}");
    assert_eq!(result["job"]["state"], "succeeded", "{ran}");
    assert_eq!(keys(result), keys(&projection(true)), "{ran}");
    assert_eq!(
        *result,
        draft.projection(
            Some(IDENTITY),
            Some(&job),
            Some(true),
            true,
            Some(result["job"].clone())
        ),
        "{ran}"
    );
    let sent = calls(&fake_root)[before..].to_vec();
    let oracle_job: Vec<String> = calls(&fixture).into_iter().take(5).collect();
    let observations = sent.len().saturating_sub(oracle_job.len());
    assert!(
        sent[..observations]
            .iter()
            .all(|call| call == "list targets -v"),
        "{sent:?}"
    );
    assert_eq!(
        sent[observations..],
        oracle_job[..],
        "the oracle's Job calls"
    );

    // run again: the settled Job, nothing run again.
    let before = calls(&fake_root).len();
    let (status, again) = continuation("run", IDENTITY);
    assert_eq!(status, Some(0), "{again}");
    assert_eq!(again["result"]["jobId"], job.as_str(), "{again}");
    assert_eq!(again["result"]["dispatched"], false, "{again}");
    assert_eq!(calls(&fake_root).len(), before, "nothing is sent again");
    daemon.stop();
    let _ = std::fs::remove_dir_all(&scratch);

    let product = arkdeck_cli::machine_contracts::contract_products()
        .into_iter()
        .find(|product| product.relative_path == "cli-feature-coverage.json")
        .expect("the CLI renders its feature coverage");
    let coverage: Value = serde_json::from_slice(&product.bytes).unwrap();
    for feature in [
        "workspace.continuation.submit",
        "workspace.continuation.run",
    ] {
        let entry = coverage["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["feature"] == feature)
            .unwrap();
        assert_eq!(
            entry["implementationStatusByPlatform"]["windows"],
            json!("implemented"),
            "{feature}"
        );
    }
}
