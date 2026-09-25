//! `workspace continuation inspect|submit|run` against what Swift decides.
//!
//! The oracle (`rust/tests/fixtures/workspace-continuation`, recorded by
//! `CLIWorkspaceContinuationOracleContractTests`) holds Swift's answers:
//! - for each source Job, whether its Target is read and the draft or refusal
//!   `CLIWorkspaceContinuationDraft.prepare` makes;
//! - for each continuation identity, the `requestJson` text of the fresh
//!   request;
//! - for each Job an identity resolves to, what `validateAcceptedJob` makes of
//!   it;
//! - the projections `submit` and `run` emit.
//!
//! Each answer is replayed through this CLI's own functions. The leaves then
//! run against a fake Runtime that serves the oracle's Runtime answers, in
//! the order Swift's handler asks for them.
use arkdeck_cli::{CliError, Draft, request_json, requires_current_target};
use serde_json::{Value, json};

const ORACLE: &str = include_str!("../../../tests/fixtures/workspace-continuation/cases.json");

fn oracle() -> Value {
    serde_json::from_str(ORACLE).unwrap()
}

/// An answer as the oracle records it: `{value}`, or the refusal's code,
/// words and details.
fn outcome<T>(result: Result<T, CliError>, value: impl FnOnce(T) -> Value) -> Value {
    match result {
        Ok(answer) => json!({"value": value(answer)}),
        Err(error) => json!({"error": {
            "code": error.code,
            "message": error.message,
            "details": Value::Object(error.details),
        }}),
    }
}

fn source<'a>(oracle: &'a Value, name: &str) -> &'a Value {
    oracle["sources"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["name"] == name)
        .unwrap_or_else(|| panic!("the oracle recorded the source {name}"))
}

/// A source case's `health`: its own, or the oracle's.
fn health<'a>(oracle: &'a Value, case: &'a Value) -> &'a Value {
    case.get("health").unwrap_or(&oracle["health"])
}

fn prepare(oracle: &Value, case: &Value) -> Result<Draft, CliError> {
    Draft::prepare(
        case["sourceJobId"].as_str().unwrap(),
        &case["show"],
        health(oracle, case),
        Some(&case["target"]).filter(|target| !target.is_null()),
    )
}

fn prepared(oracle: &Value, name: &str) -> Draft {
    prepare(oracle, source(oracle, name))
        .unwrap_or_else(|error| panic!("{name} prepares: {}", error.message))
}

#[test]
fn the_oracle_was_recorded_against_this_catalog() {
    assert_eq!(
        oracle()["cliCatalogDigest"],
        arkdeck_contract::CATALOG_DIGEST
    );
}

#[test]
fn each_source_is_judged_as_swift_judges_it() {
    let oracle = oracle();
    let sources = oracle["sources"].as_array().unwrap();
    assert!(sources.len() > 80, "{} sources", sources.len());
    for case in sources {
        let name = case["name"].as_str().unwrap();
        let job = case["sourceJobId"].as_str().unwrap();
        assert_eq!(
            outcome(requires_current_target(&case["show"], job), |needs| json!(
                needs
            )),
            case["requiresTarget"],
            "{name}: whether the Target is read"
        );
        assert_eq!(
            outcome(prepare(&oracle, case), |draft| {
                draft.projection(None, None, None, false, None)
            }),
            case["prepared"],
            "{name}: the draft"
        );
    }
}

#[test]
fn each_continuation_identity_makes_swifts_request() {
    let oracle = oracle();
    for case in oracle["requests"].as_array().unwrap() {
        let draft = prepared(&oracle, case["source"].as_str().unwrap());
        let identity = case["continuationRequestId"].as_str().unwrap();
        assert_eq!(
            outcome(draft.request(identity), |request| json!(request_json(
                &request
            ))),
            case["outcome"],
            "{} {identity}",
            case["source"]
        );
    }
}

#[test]
fn each_resolved_job_is_judged_as_swift_judges_it() {
    let oracle = oracle();
    for case in oracle["accepted"].as_array().unwrap() {
        let draft = prepared(&oracle, case["source"].as_str().unwrap());
        let expected = draft
            .request(case["continuationRequestId"].as_str().unwrap())
            .unwrap();
        assert_eq!(
            outcome(
                draft.validate_accepted_job(
                    &case["show"],
                    case["jobId"].as_str().unwrap(),
                    &expected
                ),
                |job| job
            ),
            case["outcome"],
            "{}",
            case["name"]
        );
    }
}

#[test]
fn submit_and_run_emit_swifts_projection() {
    let oracle = oracle();
    for case in oracle["projections"].as_array().unwrap() {
        let draft = prepared(&oracle, case["source"].as_str().unwrap());
        assert_eq!(
            draft.projection(
                case["continuationRequestId"].as_str(),
                case["jobId"].as_str(),
                case["deduplicated"].as_bool(),
                case["dispatched"].as_bool().unwrap(),
                Some(case["job"].clone()),
            ),
            case["value"],
            "{} dispatched {}",
            case["source"],
            case["dispatched"]
        );
    }
}

// The fake Runtime these leaves are driven against is a Unix socket.
#[cfg(target_os = "macos")]
mod support;

#[cfg(target_os = "macos")]
mod runtime {
    use super::{oracle, source, support};
    use serde_json::{Value, json};

    const SOURCE: &str = "job-source-continuation";
    const NEW: &str = "job-continuation-new";
    const TARGET: &str = "target-continuation";

    fn answer(method: &str, params: Value, result: &Value) -> (String, Value, Value) {
        (
            method.to_owned(),
            params,
            json!({"ok": true, "result": result}),
        )
    }

    fn health(result: &Value) -> (String, Value, Value) {
        answer("health", Value::Null, result)
    }

    /// The source reads Swift's handler makes, in its order: `health`, the
    /// source Job and, where Swift reads it (a device-bound source), its
    /// Target.
    fn reads(oracle: &Value, name: &str) -> Vec<(String, Value, Value)> {
        let case = source(oracle, name);
        let mut reads = vec![
            health(case.get("health").unwrap_or(&oracle["health"])),
            answer("job.show", json!({"jobId": SOURCE}), &case["show"]),
        ];
        if case["requiresTarget"]["value"] == true {
            reads.push(answer(
                "target.show",
                json!({"targetId": TARGET}),
                &case["target"],
            ));
        }
        reads
    }

    fn resolved(oracle: &Value, name: &str) -> Value {
        oracle["accepted"]
            .as_array()
            .unwrap()
            .iter()
            .find(|case| case["name"] == name)
            .unwrap_or_else(|| panic!("the oracle recorded the resolved Job {name}"))["show"]
            .clone()
    }

    fn request_text(oracle: &Value, source: &str, identity: &str) -> Value {
        oracle["requests"]
            .as_array()
            .unwrap()
            .iter()
            .find(|case| case["source"] == source && case["continuationRequestId"] == identity)
            .unwrap()["outcome"]["value"]
            .clone()
    }

    fn submit(oracle: &Value, deduplicated: bool) -> (String, Value, Value) {
        answer(
            "job.submit",
            json!({"requestJson": request_text(oracle, "deviceReadOnly", "continue-001")}),
            &json!({"schemaVersion": "arkdeck.job-acceptance/1", "jobId": NEW,
                "deduplicated": deduplicated, "newDispatchCount": 0}),
        )
    }

    fn show_new(show: &Value) -> (String, Value, Value) {
        answer("job.show", json!({"jobId": NEW}), show)
    }

    fn projection(oracle: &Value, source: &str, dispatched: bool) -> Value {
        oracle["projections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|case| case["source"] == source && case["dispatched"] == dispatched)
            .unwrap()["value"]
            .clone()
    }

    fn argv<'a>(verb: &'a str, identity: Option<&'a str>) -> Vec<&'a str> {
        let mut argv = vec!["workspace", "continuation", verb, "--source-job", SOURCE];
        if let Some(identity) = identity {
            argv.extend(["--continuation-request-id", identity]);
        }
        argv
    }

    #[test]
    fn inspect_rechecks_the_source_and_emits_the_draft() {
        let oracle = oracle();
        for name in ["deviceReadOnly", "hostOnly", "diagnosticsReadOnly"] {
            let (output, envelope) =
                support::run_session(&argv("inspect", None), reads(&oracle, name));
            assert_eq!(output.status.code(), Some(0), "{name} {envelope}");
            assert_eq!(envelope["command"], "workspace.continuation.inspect");
            assert_eq!(
                envelope["result"],
                source(&oracle, name)["prepared"]["value"],
                "{name}"
            );
        }
    }

    #[test]
    fn a_source_swift_refuses_is_refused_before_anything_is_submitted() {
        let oracle = oracle();
        for name in [
            "runtimeCatalogDrift",
            "healthProvidersDuplicate",
            "requestAuthority",
            "running",
            "diagnosticsMarkers",
            "targetRevision",
            "requestThread",
        ] {
            let (output, envelope) =
                support::run_session(&argv("submit", Some("continue-001")), reads(&oracle, name));
            let expected = &source(&oracle, name)["prepared"]["error"];
            assert_eq!(envelope["ok"], false, "{name} {envelope}");
            assert_eq!(envelope["command"], "workspace.continuation.submit");
            assert_eq!(envelope["error"]["code"], expected["code"], "{name}");
            assert_eq!(envelope["error"]["message"], expected["message"], "{name}");
            for (key, value) in expected["details"].as_object().unwrap() {
                assert_eq!(&envelope["error"]["details"][key], value, "{name} {key}");
            }
            assert_ne!(output.status.code(), Some(0), "{name}");
        }
    }

    #[test]
    fn an_identity_swift_refuses_is_refused_after_the_source_is_read() {
        let oracle = oracle();
        let (output, envelope) = support::run_session(
            &argv("submit", Some("sample")),
            reads(&oracle, "deviceReadOnly"),
        );
        assert_eq!(output.status.code(), Some(65), "{envelope}");
        assert_eq!(envelope["error"]["code"], "invalidInput");
        assert_eq!(
            envelope["error"]["message"],
            "--continuation-request-id must be 8...128 ASCII [A-Za-z0-9._-] characters"
        );
    }

    #[test]
    fn submit_admits_swifts_request_and_reads_the_job_back() {
        let oracle = oracle();
        let mut exchanges = reads(&oracle, "deviceReadOnly");
        exchanges.push(submit(&oracle, false));
        exchanges.push(show_new(&resolved(&oracle, "accepted")));
        let (output, envelope) =
            support::run_session(&argv("submit", Some("continue-001")), exchanges);
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        assert_eq!(envelope["command"], "workspace.continuation.submit");
        assert_eq!(
            envelope["result"],
            projection(&oracle, "deviceReadOnly", false)
        );

        // The identity resolves to a Job holding another request.
        let mut exchanges = reads(&oracle, "deviceReadOnly");
        exchanges.push(submit(&oracle, true));
        exchanges.push(show_new(&resolved(&oracle, "requestConflict")));
        let (_, envelope) = support::run_session(&argv("submit", Some("continue-001")), exchanges);
        assert_eq!(
            envelope["error"]["code"], "idempotencyConflict",
            "{envelope}"
        );
    }

    #[test]
    fn run_runs_a_runnable_job_once_and_reads_it_back() {
        let oracle = oracle();
        let accepted = resolved(&oracle, "accepted");
        let mut exchanges = reads(&oracle, "deviceReadOnly");
        exchanges.push(submit(&oracle, true));
        exchanges.push(show_new(&resolved(&oracle, "acceptedRunning")));
        exchanges.push(answer("job.run", json!({"jobId": NEW}), &accepted["job"]));
        exchanges.push(show_new(&accepted));
        let (output, envelope) =
            support::run_session(&argv("run", Some("continue-001")), exchanges);
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        assert_eq!(envelope["command"], "workspace.continuation.run");
        assert_eq!(
            envelope["result"],
            projection(&oracle, "deviceReadOnly", true)
        );
    }

    #[test]
    fn run_leaves_a_settled_job_alone_and_exits_by_its_outcome() {
        let oracle = oracle();
        let failed = resolved(&oracle, "acceptedFailed");
        let mut exchanges = reads(&oracle, "deviceReadOnly");
        exchanges.push(submit(&oracle, true));
        exchanges.push(show_new(&failed));
        let (output, envelope) =
            support::run_session(&argv("run", Some("continue-001")), exchanges);
        assert_eq!(output.status.code(), Some(1), "{envelope}");
        assert_eq!(envelope["ok"], true);
        assert_eq!(envelope["result"]["dispatched"], false);
        assert_eq!(envelope["result"]["job"], failed["job"]);
        assert_eq!(
            String::from_utf8_lossy(&output.stderr).trim(),
            "arkdeck: job terminal state is failed"
        );
    }

    #[test]
    fn run_refuses_a_job_it_cannot_run_or_confirm() {
        let oracle = oracle();
        // Neither runnable nor settled: the Job is left for its owner.
        let mut queued = resolved(&oracle, "acceptedRunning");
        queued["job"]["state"] = json!("queued");
        queued["job"]["outcome"] = json!("queued");
        let mut exchanges = reads(&oracle, "deviceReadOnly");
        exchanges.push(submit(&oracle, true));
        exchanges.push(show_new(&queued));
        let (_, envelope) = support::run_session(&argv("run", Some("continue-001")), exchanges);
        assert_eq!(envelope["error"]["code"], "resourceConflict", "{envelope}");
        assert_eq!(
            envelope["error"]["message"],
            "the continuation Job is queued, not runnable; inspect or resume this exact Job"
        );

        // A run whose outcome is unknown is never replayed or read on.
        let unknown = resolved(&oracle, "outcomeUnknown");
        let mut exchanges = reads(&oracle, "deviceReadOnly");
        exchanges.push(submit(&oracle, true));
        exchanges.push(show_new(&resolved(&oracle, "acceptedRunning")));
        exchanges.push(answer("job.run", json!({"jobId": NEW}), &unknown["job"]));
        let (output, envelope) =
            support::run_session(&argv("run", Some("continue-001")), exchanges);
        assert_eq!(output.status.code(), Some(75), "{envelope}");
        assert_eq!(envelope["error"]["code"], "outcomeUnknown");
        assert_eq!(
            envelope["error"]["message"],
            "the continuation run result is unconfirmed; inspect this Job and never replay it"
        );
    }
}
