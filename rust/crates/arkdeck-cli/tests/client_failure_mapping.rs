//! How this CLI names a client failure, replayed against Swift's
//! `CLIRuntimeSession.mapped` (`rust/tests/fixtures/client-failure-mapping`,
//! recorded by `CLIClientFailureMappingOracleContractTests`).
//!
//! The codes and details are Swift's for every method Swift classifies. The
//! words are Swift's for a connection that never opened, the client's own
//! deadline and a Runtime refusal. For a reply that did not come back whole
//! they are this CLI's: a read-only method keeps the transport's own text, a
//! mutation-capable one says what to read instead of repeating the request,
//! and a malformed reply says the contract was broken (declared differences).
use arkdeck_cli::{
    BOUNDED_READ_ONLY_METHODS, CLIENT_DEADLINE, CliError, bounded_read_only, failure_envelope,
};
use arkdeck_client::ClientError;
use arkdeck_contract::{ContractError, METHODS, WireError};
use serde_json::{Map, Value, json};
use std::path::Path;

fn oracle(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/client-failure-mapping")
        .join(name);
    serde_json::from_slice(
        &std::fs::read(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display())),
    )
    .unwrap()
}

fn transport(kind: std::io::ErrorKind, words: &str) -> ClientError {
    ClientError::Transport(std::io::Error::new(kind, words.to_owned()))
}

fn refused(code: &str, message: &str, details: Option<Map<String, Value>>) -> ClientError {
    ClientError::Remote(WireError {
        code: code.into(),
        message: message.into(),
        details,
    })
}

/// The details Swift gives a refusal: the Runtime's own, then the method and
/// the wire code.
fn refusal_details(method: &str, code: &str, details: Option<&Map<String, Value>>) -> Value {
    let mut expected = details.cloned().unwrap_or_default();
    expected.insert("method".into(), json!(method));
    expected.insert("wireCode".into(), json!(code));
    Value::Object(expected)
}

#[test]
fn each_recorded_failure_maps_as_swift_maps_it() {
    let cases = oracle("cases.json");
    let cases = cases["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 56);
    for case in cases {
        let method = case["method"].as_str().unwrap();
        let words = case["message"].as_str().unwrap();
        let failure = case["failure"].as_str().unwrap();
        let error = match failure {
            "connectFailed" => CliError::from_connect(
                transport(std::io::ErrorKind::ConnectionRefused, words),
                method,
            ),
            "lostResponse" => {
                CliError::from_client(transport(std::io::ErrorKind::UnexpectedEof, words), method)
            }
            "malformedResponse" => {
                CliError::from_client(ClientError::Contract(ContractError::SchemaMismatch), method)
            }
            "deadlineExceeded" => CliError::from_client(
                transport(std::io::ErrorKind::TimedOut, "control deadline exceeded"),
                method,
            ),
            "daemonError" | "refusedBeforeAdmission" | "refusedWithoutProof" => {
                let mut details = case["details"].as_object().unwrap().clone();
                details.remove("method");
                let code = details.remove("wireCode").unwrap();
                CliError::from_client(
                    refused(
                        code.as_str().unwrap(),
                        words,
                        (failure != "daemonError").then_some(details),
                    ),
                    method,
                )
            }
            other => panic!("unknown failure {other}"),
        };
        assert_eq!(error.code, case["code"], "{case}");
        assert_eq!(
            Value::Object(error.details.clone()),
            case["details"],
            "{case}"
        );
        match failure {
            "malformedResponse" if bounded_read_only(method) => assert_eq!(
                error.message,
                "the local Runtime response does not conform to the current contract"
            ),
            "lostResponse" | "malformedResponse" if !bounded_read_only(method) => {
                assert!(
                    error.message.contains("unconfirmed"),
                    "{case} {}",
                    error.message
                )
            }
            _ => assert_eq!(error.message, words, "{case}"),
        }
    }
}

/// The two declared differences, where this CLI stays more cautious than
/// Swift for a mutation-capable method: it is never told the retryable
/// `resultNotReady`, and the Runtime's own `outcomeUnknown` is never sharpened
/// by the evidence beside it. The answer this CLI gives instead of Swift's, if
/// one applies.
fn declared(
    method: &str,
    code: &str,
    details: Option<&Map<String, Value>>,
) -> Option<&'static str> {
    if bounded_read_only(method) {
        return None;
    }
    let proof = details.is_some_and(|details| {
        details.get("phase") == Some(&json!("preAdmission"))
            && details.get("newDispatchCount") == Some(&json!(0))
    });
    match code {
        "resultNotReady" if proof => Some("internalError"),
        "resultNotReady" | "outcomeUnknown" => Some("outcomeUnknown"),
        _ => None,
    }
}

#[test]
fn every_classified_method_maps_every_failure_as_swift_does() {
    let table = oracle("methods.json");
    let methods = table["methods"].as_object().unwrap();
    let wire_codes = table["wireCodes"].as_array().unwrap();
    let phases = table["ownerPhases"].as_array().unwrap();
    assert_eq!((wire_codes.len(), phases.len()), (34, 12));
    let mut variants = vec![
        (
            "preAdmission".to_owned(),
            json!({"phase":"preAdmission","newDispatchCount":0}),
        ),
        (
            "preAdmission/1".to_owned(),
            json!({"phase":"preAdmission","newDispatchCount":1}),
        ),
    ];
    for phase in phases {
        let phase = phase.as_str().unwrap();
        variants.push((
            phase.to_owned(),
            json!({"phase":phase,"newDispatchCount":0}),
        ));
        variants.push((
            format!("{phase}/1"),
            json!({"phase":phase,"newDispatchCount":1}),
        ));
    }
    let mut compared = 0;
    let mut differences = 0;
    for (method, profile) in methods {
        let profile = &table["profiles"][profile.as_str().unwrap()];
        let transport_code = |name: &str| profile["transport"][name].as_str().unwrap();
        let answers = [
            (
                "connectFailed",
                CliError::from_connect(
                    ClientError::Transport(std::io::Error::from_raw_os_error(61)),
                    method,
                ),
            ),
            (
                "lostResponse",
                CliError::from_client(
                    transport(std::io::ErrorKind::UnexpectedEof, "peer closed"),
                    method,
                ),
            ),
            (
                "malformedResponse",
                CliError::from_client(ClientError::Contract(ContractError::SchemaMismatch), method),
            ),
            (
                "deadlineExceeded",
                CliError::from_client(
                    transport(std::io::ErrorKind::TimedOut, "control deadline exceeded"),
                    method,
                ),
            ),
            // A socket's own read timeout is the same deadline.
            (
                "deadlineExceeded",
                CliError::from_client(
                    transport(
                        std::io::ErrorKind::WouldBlock,
                        "Resource temporarily unavailable",
                    ),
                    method,
                ),
            ),
            // The deadline can also pass while the connection is made.
            (
                "deadlineExceeded",
                CliError::from_connect(
                    transport(std::io::ErrorKind::TimedOut, "control deadline exceeded"),
                    method,
                ),
            ),
        ];
        for (name, error) in answers {
            assert_eq!(error.code, transport_code(name), "{method} {name}");
            assert_eq!(
                Value::Object(error.details),
                json!({"method": method}),
                "{method} {name}"
            );
            match name {
                "connectFailed" => assert_eq!(error.message, "connect failed: errno 61"),
                "deadlineExceeded" => assert_eq!(error.message, CLIENT_DEADLINE),
                _ => (),
            }
            compared += 1;
        }
        for code in wire_codes {
            let code = code.as_str().unwrap();
            let expected = &profile["refusals"][code];
            let error = CliError::from_client(refused(code, "refused", None), method);
            match declared(method, code, None) {
                Some(answer) => {
                    assert_eq!(error.code, answer, "{method} {code}");
                    differences += usize::from(expected["none"] != answer);
                }
                None => assert_eq!(error.code, expected["none"], "{method} {code}"),
            }
            assert_eq!(error.message, "refused");
            assert_eq!(
                Value::Object(error.details),
                refusal_details(method, code, None)
            );
            compared += 1;
            for (name, details) in &variants {
                let details = details.as_object().unwrap();
                let error =
                    CliError::from_client(refused(code, "refused", Some(details.clone())), method);
                let answer = expected.get(name.as_str()).unwrap_or(&expected["none"]);
                match declared(method, code, Some(details)) {
                    Some(declared) => {
                        assert_eq!(error.code, declared, "{method} {code} {name}");
                        differences += usize::from(*answer != declared);
                    }
                    None => assert_eq!(error.code, *answer, "{method} {code} {name}"),
                }
                assert_eq!(error.message, "refused");
                assert_eq!(
                    Value::Object(error.details),
                    refusal_details(method, code, Some(details))
                );
                compared += 1;
            }
        }
    }
    // Each method: 6 transport answers, and 34 wire codes under 27 kinds of
    // evidence.
    assert_eq!(compared, methods.len() * (6 + 34 * 27));
    // Where Swift answers otherwise, for each of the 52 mutation-capable
    // methods: `resultNotReady` under all 27 kinds of evidence, and the
    // Runtime's own `outcomeUnknown` under the pre-admission proof.
    assert_eq!(differences, 52 * 27 + 52);
}

#[test]
fn the_read_only_methods_are_swifts() {
    let table = oracle("methods.json");
    let methods = table["methods"].as_object().unwrap();
    for (method, profile) in methods {
        let effect = &table["profiles"][profile.as_str().unwrap()]["effect"];
        assert_eq!(
            bounded_read_only(method),
            effect == "boundedReadOnly",
            "{method}"
        );
    }
    // The same set, directly: Swift's bounded reads are this CLI's.
    let swift: std::collections::BTreeSet<&str> = methods
        .iter()
        .filter(|(_, profile)| {
            table["profiles"][profile.as_str().unwrap()]["effect"] == "boundedReadOnly"
        })
        .map(|(method, _)| method.as_str())
        .collect();
    let rust: std::collections::BTreeSet<&str> = BOUNDED_READ_ONLY_METHODS.into_iter().collect();
    assert_eq!(rust, swift);
    assert_eq!(rust.len(), 53);
    // A method Swift has not classified is mutation-capable, as in Swift.
    for method in METHODS {
        if !methods.contains_key(*method) {
            assert!(!bounded_read_only(method), "{method}");
        }
    }
    assert!(!bounded_read_only("unclassified.method"));
}

/// A contract the preflight could not prove, or a request this client
/// refused to encode, was refused before the request left: Swift's code for
/// every method. Swift adds the pre-admission proof to its details; this
/// client names the method only (a declared difference).
#[test]
fn an_unproven_contract_is_unsupported_for_every_method() {
    let table = oracle("methods.json");
    for method in table["methods"].as_object().unwrap().keys() {
        for failure in [
            ContractError::ContractMismatch,
            ContractError::UnsupportedVersion,
        ] {
            let error = CliError::from_client(ClientError::Contract(failure), method);
            assert_eq!(error.code, "protocolVersionUnsupported", "{method}");
            assert_eq!(Value::Object(error.details), json!({"method": method}));
        }
    }
}

/// Whether a caller may send the same control request again.
fn retryable(method: &str, error: &CliError) -> bool {
    failure_envelope(method, error, "ctl-structure", true)["error"]["controlRequestRetryable"]
        == true
}

/// Once a mutation-capable method's request is out, nothing but proof may say
/// it did nothing: a lost or malformed reply, a connection that ended, or the
/// client's own deadline is an unknown outcome, never a retryable code. This
/// holds for every published method the effect table does not name a bounded
/// read, so a method added later is held to it too.
#[test]
fn a_mutation_capable_request_that_went_out_is_an_unknown_outcome() {
    let mut mutation_capable = 0;
    for method in METHODS.iter().chain(["an.unclassified.method"].iter()) {
        if bounded_read_only(method) {
            continue;
        }
        mutation_capable += 1;
        let failures = [
            transport(std::io::ErrorKind::UnexpectedEof, "peer closed"),
            transport(std::io::ErrorKind::ConnectionReset, "reset"),
            transport(std::io::ErrorKind::ConnectionAborted, "aborted"),
            transport(std::io::ErrorKind::BrokenPipe, "broken pipe"),
            transport(std::io::ErrorKind::TimedOut, "control deadline exceeded"),
            transport(
                std::io::ErrorKind::WouldBlock,
                "Resource temporarily unavailable",
            ),
            ClientError::Contract(ContractError::SchemaMismatch),
            ClientError::Contract(ContractError::Malformed),
            ClientError::Contract(ContractError::DuplicateKey),
            ClientError::Contract(ContractError::IntegerBeyondExactRange),
            ClientError::ConnectionUnusable,
        ];
        for failure in failures {
            let label = format!("{failure:?}");
            let error = CliError::from_client(failure, method);
            assert_eq!(error.code, "outcomeUnknown", "{method} {label}");
            assert_eq!(error.exit_code(), 75, "{method} {label}");
            assert!(!retryable(method, &error), "{method} {label}");
            assert_eq!(error.details["method"], json!(method));
        }
    }
    assert!(mutation_capable > 50, "{mutation_capable}");
}

/// No refusal the Runtime can send makes a mutation-capable request retryable:
/// whatever its code and evidence, retrying it could dispatch it twice, which
/// POL-RECOVERY-001 forbids.
#[test]
fn no_refusal_makes_a_mutation_capable_request_retryable() {
    let table = oracle("methods.json");
    let mut codes: Vec<&str> = table["wireCodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|code| code.as_str().unwrap())
        .collect();
    // The codes a caller could retry, sent as the Runtime's own.
    codes.extend(["clientTimeout", "runtimeUnavailable"]);
    let mut evidence = vec![None, Some(json!({}))];
    for phase in [
        "preAdmission",
        "bootstrapRegistryOwner",
        "sessionOwner",
        "importOwner",
    ] {
        for count in [0, 1] {
            evidence.push(Some(json!({"phase": phase, "newDispatchCount": count})));
        }
    }
    for method in METHODS.iter().chain(["an.unclassified.method"].iter()) {
        if bounded_read_only(method) {
            continue;
        }
        for code in &codes {
            for details in &evidence {
                let details = details
                    .as_ref()
                    .map(|details| details.as_object().unwrap().clone());
                let error = CliError::from_client(refused(code, "refused", details), method);
                assert!(!retryable(method, &error), "{method} {code} {}", error.code);
            }
        }
    }
}

/// §8.4, as the hub classified it: a refusal of a mutation-capable request
/// that carries no zero-dispatch evidence keeps a code only where §8.4's fixed
/// fallback table names one (class A, with Swift's same pass-through of
/// `workspaceReferenceNotFound`); anything else is `outcomeUnknown` (class C).
/// Evidence that proves nothing: none, an empty object, a dispatch counted, a
/// phase or a count alone, or a phase no owner uses. Holds for every published
/// method, so a method added later is held to it too.
#[test]
fn an_unproven_refusal_of_a_mutation_is_an_unknown_outcome_unless_the_spec_fixes_it() {
    let fixed = std::collections::BTreeMap::from([
        ("unsupportedProtocolVersion", "protocolVersionUnsupported"),
        ("malformedFrame", "protocolMalformed"),
        ("unknownMethod", "controlMethodUnavailable"),
        ("invalidParams", "invalidInput"),
        ("conflict", "resourceConflict"),
        ("notFound", "resourceNotFound"),
        ("recordUnreadable", "recordUnreadable"),
        ("workspaceReferenceNotFound", "workspaceReferenceNotFound"),
    ]);
    let table = oracle("methods.json");
    let mut codes: Vec<&str> = table["wireCodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|code| code.as_str().unwrap())
        .collect();
    codes.extend(["clientTimeout", "runtimeUnavailable"]);
    let mut unproven = vec![
        None,
        Some(json!({})),
        Some(json!({"phase": "preAdmission"})),
        Some(json!({"newDispatchCount": 0})),
        Some(json!({"phase": "noOwner", "newDispatchCount": 0})),
    ];
    let mut phases: Vec<&str> = table["ownerPhases"]
        .as_array()
        .unwrap()
        .iter()
        .map(|phase| phase.as_str().unwrap())
        .collect();
    phases.push("preAdmission");
    for phase in phases {
        unproven.push(Some(json!({"phase": phase, "newDispatchCount": 1})));
    }
    let mut checked = 0;
    for method in METHODS.iter().chain(["an.unclassified.method"].iter()) {
        if bounded_read_only(method) {
            continue;
        }
        for code in &codes {
            for details in &unproven {
                let details = details
                    .as_ref()
                    .map(|details| details.as_object().unwrap().clone());
                let error = CliError::from_client(refused(code, "refused", details), method);
                let expected = fixed.get(code).copied().unwrap_or("outcomeUnknown");
                assert_eq!(error.code, expected, "{method} {code}");
                checked += 1;
            }
        }
    }
    assert!(checked > 50 * 36 * 18, "{checked}");
}

/// Before any byte of the request left, nothing was accepted, whatever the
/// method: every published method is `runtimeUnavailable` and retryable when
/// the connection never opened (Swift's `connectFailed`).
#[test]
fn a_connection_that_never_opened_is_unavailable_for_every_method() {
    for method in METHODS.iter().chain(["an.unclassified.method"].iter()) {
        for failure in [
            ClientError::Transport(std::io::Error::from_raw_os_error(2)),
            ClientError::Transport(std::io::Error::from_raw_os_error(61)),
            transport(
                std::io::ErrorKind::PermissionDenied,
                "endpoint must be an owner-only 0600 socket",
            ),
        ] {
            let error = CliError::from_connect(failure, method);
            assert_eq!(error.code, "runtimeUnavailable", "{method}");
            assert!(retryable(method, &error), "{method}");
            assert_eq!(Value::Object(error.details), json!({"method": method}));
        }
    }
}

#[cfg(target_os = "macos")]
mod support;

#[cfg(target_os = "macos")]
mod leaves {
    use super::support;
    use arkdeck_contract::{CATALOG_DIGEST, METHODS, PROTOCOL_VERSION};
    use serde_json::{Value, json};
    use std::os::unix::fs::DirBuilderExt;
    use std::process::Command;

    /// A connection that never opened sent nothing, so every leaf, whatever its
    /// method can do, is `runtimeUnavailable`, retryable and in Swift's words.
    /// (`agent resume --resume-token` resumes on the client, as Swift's
    /// `usesRuntimeExecution` routes it, and opens no connection before its
    /// pending record is read: `domain_leaves.rs` replays it.)
    #[test]
    fn a_connection_that_never_opened_is_unavailable_whatever_the_method() {
        let root = std::fs::canonicalize("/tmp").unwrap().join(format!(
            "arkdeck-cli-absent-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&root)
            .unwrap();
        let socket = root.join("absent.sock");
        for (argv, method) in [
            (vec!["job", "run", "--job", "job-a"], "job.run"),
            (vec!["job", "cancel", "--job", "job-a"], "job.cancel"),
            (vec!["job", "reconcile", "--job", "job-a"], "job.reconcile"),
            (vec!["job", "status", "--job", "job-a"], "job.status"),
            (vec!["runtime", "health"], "health"),
            (
                vec!["agent", "status", "--execution-id", "execution-a"],
                "agent.status",
            ),
            (
                vec![
                    "flash",
                    "reconcile-alias",
                    "--target",
                    "TGT-A",
                    "--expected-binding-revision",
                    "2",
                ],
                "flash.reconcile-alias",
            ),
        ] {
            let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
                .args(&argv)
                .args(["--output", "json", "--socket"])
                .arg(&socket)
                .output()
                .unwrap();
            let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(output.status.code(), Some(69), "{argv:?} {envelope}");
            assert_eq!(envelope["error"]["code"], "runtimeUnavailable", "{argv:?}");
            assert_eq!(envelope["error"]["message"], "connect failed: errno 2");
            assert_eq!(envelope["error"]["details"], json!({"method": method}));
            assert_eq!(envelope["error"]["controlRequestRetryable"], true);
        }
        std::fs::remove_dir(root).unwrap();
    }

    /// A contract the Runtime cannot prove ends the request before its
    /// business frame is written: the fake Runtime reads the preflight
    /// `health` and nothing else (the harness fails on any further frame or
    /// connection), and a mutation-capable leaf answers
    /// `protocolVersionUnsupported`, which is not retryable. The Runtime here
    /// publishes another contract identity in a well-formed `health`.
    #[test]
    fn a_contract_the_runtime_cannot_prove_sends_no_business_frame() {
        let health = json!({"ok": true, "result": {
            "status": "ok",
            "protocolVersion": PROTOCOL_VERSION,
            "contractIdentity": "0".repeat(64),
            "catalogDigest": CATALOG_DIGEST,
            "providers": ["hdc"],
            "publishedMethods": METHODS,
        }});
        let digest = "a".repeat(64);
        for (argv, method) in [
            (vec!["trace", "cache", "purge"], "trace.cache.purge"),
            (
                vec![
                    "target",
                    "display-name",
                    "set",
                    "--target",
                    "target-a",
                    "--expected-generation",
                    "1",
                    "--name",
                    "Bench",
                ],
                "target.display-name.set",
            ),
            (
                vec![
                    "session",
                    "cleanup",
                    "apply",
                    "--preview-id",
                    "00000000-0000-0000-0000-000000000001",
                    "--preview-digest",
                    &digest,
                ],
                "session.cleanup.apply",
            ),
        ] {
            let (output, envelope) = support::run_session(
                &argv,
                vec![("health".to_owned(), Value::Null, health.clone())],
            );
            assert_eq!(output.status.code(), Some(69), "{argv:?} {envelope}");
            assert_eq!(envelope["error"]["code"], "protocolVersionUnsupported");
            assert_eq!(envelope["error"]["controlRequestRetryable"], false);
            assert_eq!(envelope["error"]["details"], json!({"method": method}));
        }
    }
}
