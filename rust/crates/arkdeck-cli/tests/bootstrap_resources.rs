use arkdeck_cli::{parse, validate_bootstrap_response};
use serde_json::{Value, json};

#[test]
fn existing_bootstrap_argv_fixtures_keep_their_dispatch_contract() {
    for corpus in [
        include_str!("../../../tests/fixtures/current-cli-argv/runtime.tool.list.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/runtime.tool.remove.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/runtime.tool.inspect.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/runtime.bundle.inspect.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/runtime.bundle.list.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/runtime.bundle.remove.json"),
    ] {
        let corpus: Value = serde_json::from_str(corpus).unwrap();
        for case in corpus["cases"].as_array().unwrap() {
            let argv: Vec<String> = case["argv"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap().into())
                .collect();
            let result = parse(&argv);
            if case["name"] == "macosCompatibilityOption" && !cfg!(target_os = "macos") {
                assert_eq!(result.unwrap_err().code, "unsupportedOnPlatform");
            } else if case["expected"]["outcome"] == "failure" {
                assert_eq!(result.unwrap_err().code, case["expected"]["code"], "{case}");
            } else {
                let actual = result.unwrap();
                assert_eq!(actual.command, case["expected"]["command"], "{case}");
            }
        }
    }
}
#[test]
fn actual_bootstrap_producer_results_preserve_exact_identity_and_no_execution_assessment() {
    for (method, family, flag) in [
        ("runtime.tool.inspect", "tool", "--tool"),
        ("runtime.bundle.inspect", "bundle", "--bundle"),
    ] {
        if !arkdeck_contract::METHODS.contains(&method) {
            // Old published contract inputs contain no result for the new RPC.
            // The candidate view consumes the actual new producer recordings.
            continue;
        }
        let path=std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"));
        let corpus = std::fs::read_to_string(path).unwrap();
        let mut successes = 0;
        for row in corpus
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
        {
            if row["ok"] != true {
                continue;
            }
            successes += 1;
            let result = row["result"].clone();
            let reference = row["params"][family].as_str().unwrap();
            let argv: Vec<String> = ["runtime", family, "inspect", flag, reference]
                .into_iter()
                .map(str::to_owned)
                .collect();
            let invocation = parse(&argv).unwrap();
            validate_bootstrap_response(&invocation, &result).unwrap();
            for (key, value) in [
                ("generation", json!("0")),
                ("contentDigest", json!("0".repeat(64))),
                (
                    "contentRetained",
                    json!(!result["contentRetained"].as_bool().unwrap()),
                ),
            ] {
                let mut malformed = result.clone();
                malformed[key] = value;
                assert_eq!(
                    validate_bootstrap_response(&invocation, &malformed)
                        .unwrap_err()
                        .code,
                    "recordUnreadable"
                );
            }
        }
        assert!(
            successes > 0,
            "{method} must have actual producer success evidence"
        );
    }
}

fn bundle_list(options: &[&str]) -> arkdeck_cli::Invocation {
    let argv = ["runtime", "bundle", "list"]
        .into_iter()
        .chain(options.iter().copied())
        .map(str::to_owned)
        .collect::<Vec<_>>();
    parse(&argv).unwrap()
}

#[test]
fn bundle_list_options_use_typed_bounded_pages_and_keep_cursor_opaque() {
    assert_eq!(
        bundle_list(&[]).params.unwrap(),
        json!({"pageSize":100}).as_object().unwrap().clone()
    );
    let invocation = bundle_list(&["--page-size", "1000", "--cursor", "opaque"]);
    assert_eq!(invocation.method, "runtime.bundle.list");
    assert_eq!(
        invocation.params.unwrap(),
        json!({"pageSize":1000,"cursor":"opaque"})
            .as_object()
            .unwrap()
            .clone()
    );
    for options in [
        vec!["--page-size", "0"],
        vec!["--page-size", "1001"],
        vec!["--page-size", "1.0"],
        vec!["--bundle", "sample"],
        vec!["--tool", "sample"],
    ] {
        let argv = ["runtime", "bundle", "list"]
            .into_iter()
            .chain(options)
            .map(str::to_owned)
            .collect::<Vec<_>>();
        assert_eq!(parse(&argv).unwrap_err().code, "invalidOption");
    }
    assert!(bundle_list(&["--help"]).help);
}

#[test]
fn bundle_list_maps_only_bounded_bootstrap_owner_errors() {
    for code in [
        "invalidCursor",
        "admissionDenied",
        "ioFailure",
        "inputTooLarge",
        "operationUnavailable",
    ] {
        for count in [0, 1] {
            let error = arkdeck_client::ClientError::Remote(arkdeck_contract::WireError {
                code: code.into(),
                message: "owner refused".into(),
                details: Some(
                    json!({"phase":"bootstrapRegistryOwner","newDispatchCount":count})
                        .as_object()
                        .unwrap()
                        .clone(),
                ),
            });
            let mapped = arkdeck_cli::CliError::from_client(error, "runtime.bundle.list");
            assert_eq!(mapped.code, if count == 0 { code } else { "internalError" });
        }
    }
}

#[test]
fn actual_bundle_pages_preserve_snapshot_and_validate_every_row() {
    if !arkdeck_contract::METHODS.contains(&"runtime.bundle.list") {
        let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
        assert_ne!(
            inputs["kind"], "candidate",
            "candidate must expose bundle list"
        );
        return;
    }
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/runtime.bundle.list.jsonl");
    let corpus = std::fs::read_to_string(path).unwrap();
    let mut pages = 0;
    let mut rows = 0;
    for frame in corpus
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter(|v| v["ok"] == true)
    {
        let mut invocation = bundle_list(&[]);
        invocation.params = Some(frame["params"].as_object().unwrap().clone());
        invocation
            .params
            .as_mut()
            .unwrap()
            .entry("pageSize")
            .or_insert(json!(100));
        let page = &frame["result"];
        validate_bootstrap_response(&invocation, page).unwrap();
        pages += 1;
        if let Some(first) = page["items"].as_array().unwrap().first() {
            let mut duplicate = page.clone();
            duplicate["items"] = json!([first, first]);
            assert_eq!(
                validate_bootstrap_response(&invocation, &duplicate)
                    .unwrap_err()
                    .code,
                "recordUnreadable"
            );
            let mut continued = invocation.clone();
            continued.params.as_mut().unwrap().insert(
                "cursor".into(),
                json!("00000000-0000-0000-0000-000000000000.11111111-1111-1111-1111-111111111111"),
            );
            assert_eq!(
                validate_bootstrap_response(&continued, page)
                    .unwrap_err()
                    .code,
                "recordUnreadable"
            );
        }
        for (pointer, malformed) in [
            ("/order", json!("other")),
            ("/snapshotRevision", json!("invalid")),
            ("/nextCursor", json!(17)),
            ("/pageKind", json!("eventStream")),
        ] {
            let mut damaged = page.clone();
            *damaged.pointer_mut(pointer).unwrap() = malformed;
            assert_eq!(
                validate_bootstrap_response(&invocation, &damaged)
                    .unwrap_err()
                    .code,
                "recordUnreadable"
            );
        }
        for index in 0..page["items"].as_array().unwrap().len() {
            rows += 1;
            for (key, malformed) in [
                ("generation", json!("0")),
                ("contentDigest", json!("z".repeat(64))),
                ("contentRetained", json!(false)),
                (
                    "bundleRef",
                    json!("bundle:sha256:".to_owned() + &"0".repeat(64)),
                ),
            ] {
                let mut damaged = page.clone();
                damaged["items"][index][key] = malformed;
                assert_eq!(
                    validate_bootstrap_response(&invocation, &damaged)
                        .unwrap_err()
                        .code,
                    "recordUnreadable"
                );
            }
        }
    }
    assert!(
        pages > 0 && rows > 0,
        "actual producer must exercise bundle discovery"
    );
}

fn retirement(options: &[&str]) -> Result<arkdeck_cli::Invocation, arkdeck_cli::CliError> {
    let argv = ["runtime", "bundle", "remove"]
        .into_iter()
        .chain(options.iter().copied())
        .map(str::to_owned)
        .collect::<Vec<_>>();
    parse(&argv)
}

#[test]
fn bundle_retirement_requires_exact_generation_text_and_reference() {
    for generation in ["1", "2", "9223372036854775807"] {
        let invocation =
            retirement(&["--bundle", "sample", "--expected-generation", generation]).unwrap();
        assert_eq!(invocation.method, "runtime.bundle.remove");
        assert_eq!(
            invocation.params.unwrap(),
            json!({"bundle":"sample","expectedGeneration":generation})
                .as_object()
                .unwrap()
                .clone()
        );
    }
    for generation in ["0", "+1", "01", " 1", "-1", "1.0", "9223372036854775808"] {
        assert_eq!(
            retirement(&["--bundle", "sample", "--expected-generation", generation])
                .unwrap_err()
                .code,
            "invalidOption"
        );
    }
    for options in [
        vec![],
        vec!["--bundle", "sample"],
        vec!["--expected-generation", "1"],
        vec![
            "--bundle",
            "sample",
            "--expected-generation",
            "1",
            "--page-size",
            "1",
        ],
    ] {
        assert_eq!(retirement(&options).unwrap_err().code, "invalidOption");
    }
    assert!(retirement(&["--help"]).unwrap().help);
}

#[test]
fn retirement_preserves_only_proven_owner_failures_and_existing_protocol_refusals() {
    use arkdeck_client::ClientError;
    use arkdeck_contract::{ContractError, WireError};
    for code in [
        "invalidInput",
        "resourceNotFound",
        "resourceConflict",
        "admissionDenied",
        "recordUnreadable",
        "quotaExceeded",
        "operationUnavailable",
        "outcomeUnknown",
    ] {
        if arkdeck_contract::METHODS.contains(&"runtime.bundle.remove") {
            arkdeck_contract::validate_method_value(
                "runtime.bundle.remove",
                "errorCode",
                &json!(code),
            )
            .unwrap();
        }
        let missing_proof = arkdeck_cli::CliError::from_client(
            ClientError::Remote(WireError {
                code: code.into(),
                message: "owner refused without proof".into(),
                details: None,
            }),
            "runtime.bundle.remove",
        );
        assert_eq!(missing_proof.code, "outcomeUnknown");
        assert!(!missing_proof.details.contains_key("newDispatchCount"));
        for (phase, count) in [
            ("bootstrapRegistryOwner", 0),
            ("bootstrapRegistryOwner", 1),
            ("otherOwner", 0),
        ] {
            let mapped = arkdeck_cli::CliError::from_client(
                ClientError::Remote(WireError {
                    code: code.into(),
                    message: "owner refused".into(),
                    details: Some(
                        json!({"phase":phase,"newDispatchCount":count})
                            .as_object()
                            .unwrap()
                            .clone(),
                    ),
                }),
                "runtime.bundle.remove",
            );
            assert_eq!(
                mapped.code,
                if phase == "bootstrapRegistryOwner" && count == 0 {
                    code
                } else {
                    "outcomeUnknown"
                }
            );
            assert_eq!(mapped.details["newDispatchCount"], count);
        }
    }
    for (code, mapped) in [
        ("unknownMethod", "controlMethodUnavailable"),
        ("invalidParams", "invalidInput"),
        ("malformedFrame", "protocolMalformed"),
        ("unsupportedProtocolVersion", "protocolVersionUnsupported"),
    ] {
        assert_eq!(
            arkdeck_cli::CliError::from_client(
                ClientError::Remote(WireError {
                    code: code.into(),
                    message: "refused".into(),
                    details: None
                }),
                "runtime.bundle.remove"
            )
            .code,
            mapped
        );
    }
    for error in [
        ClientError::Transport(std::io::Error::from(std::io::ErrorKind::ConnectionReset)),
        ClientError::Transport(std::io::Error::from(std::io::ErrorKind::TimedOut)),
        ClientError::ConnectionUnusable,
        ClientError::Contract(ContractError::SchemaMismatch),
        ClientError::Contract(ContractError::Malformed),
    ] {
        let mapped = arkdeck_cli::CliError::from_client(error, "runtime.bundle.remove");
        assert_eq!(mapped.code, "outcomeUnknown");
        assert_eq!(mapped.exit_code(), 75);
        assert!(!mapped.details.contains_key("newDispatchCount"));
    }
}

#[test]
fn actual_retirement_receipts_match_the_requested_bundle_and_retain_content() {
    if !arkdeck_contract::METHODS.contains(&"runtime.bundle.remove") {
        let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
        assert_ne!(
            inputs["kind"], "candidate",
            "candidate must expose bundle retirement"
        );
        return;
    }
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/runtime.bundle.remove.jsonl");
    let corpus = std::fs::read_to_string(path).unwrap();
    let mut receipts = 0;
    for frame in corpus
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter(|v| v["ok"] == true)
    {
        let invocation = retirement(&[
            "--bundle",
            frame["params"]["bundle"].as_str().unwrap(),
            "--expected-generation",
            frame["params"]["expectedGeneration"].as_str().unwrap(),
        ])
        .unwrap();
        let receipt = &frame["result"];
        validate_bootstrap_response(&invocation, receipt).unwrap();
        receipts += 1;
        for (key, value) in [
            ("state", json!("available")),
            ("generation", json!("1")),
            ("generation", json!("3")),
            ("contentRetained", json!(false)),
            ("contentDigest", json!("invalid")),
            (
                "bundleRef",
                json!("bundle:sha256:".to_owned() + &"0".repeat(64)),
            ),
        ] {
            let mut malformed = receipt.clone();
            malformed[key] = value;
            assert_eq!(
                validate_bootstrap_response(&invocation, &malformed)
                    .unwrap_err()
                    .code,
                "outcomeUnknown"
            );
        }
    }
    assert!(
        receipts > 0,
        "candidate must consume the actual native retirement receipt"
    );
}

#[test]
fn in_memory_lost_retirement_receipt_is_unknown_and_the_client_never_replays() {
    use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
    use std::io::{Cursor, Read, Write};
    use std::{cell::RefCell, rc::Rc};
    if !METHODS.contains(&"runtime.bundle.remove") {
        return;
    }
    struct Stream {
        replies: Cursor<Vec<u8>>,
        sent: Rc<RefCell<Vec<u8>>>,
    }
    impl Read for Stream {
        fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
            self.replies.read(bytes)
        }
    }
    impl Write for Stream {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.sent.borrow_mut().extend(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let health = json!({"id":"health","ok":true,"result":{"status":"ok","protocolVersion":PROTOCOL_VERSION,"contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,"providers":[],"publishedMethods":METHODS}});
    let mut reply = serde_json::to_vec(&health).unwrap();
    reply.push(b'\n');
    let sent = Rc::new(RefCell::new(Vec::new()));
    let mut client = arkdeck_client::Client::new(Stream {
        replies: Cursor::new(reply),
        sent: sent.clone(),
    });
    let invocation = retirement(&[
        "--bundle",
        &("bundle:sha256:".to_owned() + &"a".repeat(64)),
        "--expected-generation",
        "1",
    ])
    .unwrap();
    let error = client
        .request("remove-once", invocation.method, invocation.params.clone())
        .unwrap_err();
    assert_eq!(
        arkdeck_cli::CliError::from_client(error, invocation.method).code,
        "outcomeUnknown"
    );
    let before = sent.borrow().clone();
    let requests = String::from_utf8(before.clone())
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0]["method"], "health");
    assert_eq!(requests[1]["method"], "runtime.bundle.remove");
    assert!(matches!(
        client.request("retry-refused", invocation.method, invocation.params),
        Err(arkdeck_client::ClientError::ConnectionUnusable)
    ));
    assert_eq!(*sent.borrow(), before);
}

fn tool_retirement(options: &[&str]) -> Result<arkdeck_cli::Invocation, arkdeck_cli::CliError> {
    parse(
        &["runtime", "tool", "remove"]
            .into_iter()
            .chain(options.iter().copied())
            .map(str::to_owned)
            .collect::<Vec<_>>(),
    )
}

#[test]
fn tool_retirement_keeps_exact_typed_generation_and_both_reference_families() {
    for reference in ["tool:sha256:", "toolchain:sha256:"] {
        let reference = format!("{reference}{}", "a".repeat(64));
        for generation in ["1", "2", "9223372036854775807"] {
            let invocation =
                tool_retirement(&["--tool", &reference, "--expected-generation", generation])
                    .unwrap();
            assert_eq!(invocation.method, "runtime.tool.remove");
            assert_eq!(
                invocation.params.unwrap(),
                json!({"tool":reference,"expectedGeneration":generation})
                    .as_object()
                    .unwrap()
                    .clone()
            );
        }
    }
    for generation in ["0", "+1", "01", " 1", "-1", "1.0", "9223372036854775808"] {
        assert_eq!(
            tool_retirement(&["--tool", "sample", "--expected-generation", generation])
                .unwrap_err()
                .code,
            "invalidOption"
        );
    }
    for options in [
        vec![],
        vec!["--tool", "sample"],
        vec!["--expected-generation", "1"],
        vec![
            "--tool",
            "sample",
            "--expected-generation",
            "1",
            "--page-size",
            "1",
        ],
    ] {
        assert_eq!(tool_retirement(&options).unwrap_err().code, "invalidOption");
    }
    assert!(tool_retirement(&["--help"]).unwrap().help);
}

#[test]
fn tool_retirement_owner_errors_require_exact_proof_and_match_the_schema() {
    use arkdeck_client::ClientError;
    use arkdeck_contract::{ContractError, WireError};
    for code in [
        "invalidInput",
        "resourceNotFound",
        "resourceConflict",
        "admissionDenied",
        "recordUnreadable",
        "ioFailure",
        "fileIdentityChanged",
        "inputTooLarge",
        "quotaExceeded",
        "operationUnavailable",
        "outcomeUnknown",
    ] {
        if arkdeck_contract::METHODS.contains(&"runtime.tool.remove") {
            arkdeck_contract::validate_method_value(
                "runtime.tool.remove",
                "errorCode",
                &json!(code),
            )
            .unwrap();
        }
        for details in [
            None,
            Some(json!({"phase":"bootstrapRegistryOwner","newDispatchCount":0})),
            Some(json!({"phase":"bootstrapRegistryOwner","newDispatchCount":1})),
            Some(json!({"phase":"otherOwner","newDispatchCount":0})),
        ] {
            let proven = details.as_ref().is_some_and(|d| {
                d["phase"] == "bootstrapRegistryOwner" && d["newDispatchCount"] == 0
            });
            let mapped = arkdeck_cli::CliError::from_client(
                ClientError::Remote(WireError {
                    code: code.into(),
                    message: "owner refused".into(),
                    details: details.as_ref().map(|d| d.as_object().unwrap().clone()),
                }),
                "runtime.tool.remove",
            );
            assert_eq!(mapped.code, if proven { code } else { "outcomeUnknown" });
            let expected_exit = if !proven {
                75
            } else {
                match code {
                    "invalidInput" | "resourceNotFound" | "resourceConflict" | "inputTooLarge" => {
                        65
                    }
                    "admissionDenied" | "fileIdentityChanged" => 77,
                    "recordUnreadable" => 2,
                    "quotaExceeded" | "operationUnavailable" => 69,
                    "ioFailure" => 74,
                    "outcomeUnknown" => 75,
                    _ => unreachable!(),
                }
            };
            assert_eq!(mapped.exit_code(), expected_exit);
            if details.is_none() {
                assert!(!mapped.details.contains_key("newDispatchCount"));
            }
        }
    }
    for (wire, code) in [
        ("unknownMethod", "controlMethodUnavailable"),
        ("invalidParams", "invalidInput"),
        ("malformedFrame", "protocolMalformed"),
        ("unsupportedProtocolVersion", "protocolVersionUnsupported"),
    ] {
        assert_eq!(
            arkdeck_cli::CliError::from_client(
                ClientError::Remote(WireError {
                    code: wire.into(),
                    message: "refused".into(),
                    details: None
                }),
                "runtime.tool.remove"
            )
            .code,
            code
        );
    }
    for error in [
        ClientError::Transport(std::io::Error::from(std::io::ErrorKind::ConnectionReset)),
        ClientError::Transport(std::io::Error::from(std::io::ErrorKind::TimedOut)),
        ClientError::ConnectionUnusable,
        ClientError::Contract(ContractError::SchemaMismatch),
        ClientError::Contract(ContractError::Malformed),
    ] {
        let error = arkdeck_cli::CliError::from_client(error, "runtime.tool.remove");
        assert_eq!(error.code, "outcomeUnknown");
        assert_eq!(error.exit_code(), 75);
        assert!(!error.details.contains_key("newDispatchCount"));
    }
}

#[test]
fn actual_tool_retirement_receipts_preserve_both_content_models() {
    if !arkdeck_contract::METHODS.contains(&"runtime.tool.remove") {
        let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
        assert_ne!(
            inputs["kind"], "candidate",
            "candidate must expose tool retirement"
        );
        return;
    }
    let path=std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/runtime.tool.remove.jsonl");
    let corpus = std::fs::read_to_string(path).unwrap();
    let mut kinds = std::collections::BTreeSet::new();
    for frame in corpus
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter(|frame| frame["ok"] == true)
    {
        let invocation = tool_retirement(&[
            "--tool",
            frame["params"]["tool"].as_str().unwrap(),
            "--expected-generation",
            frame["params"]["expectedGeneration"].as_str().unwrap(),
        ])
        .unwrap();
        let receipt = &frame["result"];
        validate_bootstrap_response(&invocation, receipt).unwrap();
        kinds.insert(receipt["kind"].as_str().unwrap().to_owned());
        for (key, bad) in [
            ("state", json!("available")),
            ("generation", json!("1")),
            ("generation", json!("3")),
            ("selected", json!(true)),
            ("contentDigest", json!("invalid")),
            (
                "contentRetained",
                json!(!receipt["contentRetained"].as_bool().unwrap()),
            ),
            (
                "references",
                json!([{"kind":"activeSelection","id":"runtime-hdc-selection"}]),
            ),
        ] {
            let mut damaged = receipt.clone();
            damaged[key] = bad;
            assert_eq!(
                validate_bootstrap_response(&invocation, &damaged)
                    .unwrap_err()
                    .code,
                "outcomeUnknown"
            );
        }
        let mut mismatched = invocation.clone();
        mismatched.params.as_mut().unwrap().insert(
            "tool".into(),
            json!("tool:sha256:".to_owned() + &"0".repeat(64)),
        );
        assert_eq!(
            validate_bootstrap_response(&mismatched, receipt)
                .unwrap_err()
                .code,
            "outcomeUnknown"
        );
    }
    assert_eq!(
        kinds,
        std::collections::BTreeSet::from(["hdc".into(), "deveco".into()]),
        "candidate must consume both actual producer families"
    );
}

#[test]
fn in_memory_tool_retirement_lost_receipt_cannot_replay() {
    use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
    use std::{
        cell::RefCell,
        io::{Cursor, Read, Write},
        rc::Rc,
    };
    if !METHODS.contains(&"runtime.tool.remove") {
        return;
    }
    struct Stream {
        response: Cursor<Vec<u8>>,
        sent: Rc<RefCell<Vec<u8>>>,
    }
    impl Read for Stream {
        fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
            self.response.read(bytes)
        }
    }
    impl Write for Stream {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.sent.borrow_mut().extend(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let health = json!({"id":"health","ok":true,"result":{"status":"ok","protocolVersion":PROTOCOL_VERSION,"contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,"providers":[],"publishedMethods":METHODS}});
    let mut response = serde_json::to_vec(&health).unwrap();
    response.push(b'\n');
    let sent = Rc::new(RefCell::new(Vec::new()));
    let mut client = arkdeck_client::Client::new(Stream {
        response: Cursor::new(response),
        sent: sent.clone(),
    });
    let invocation = tool_retirement(&[
        "--tool",
        &("tool:sha256:".to_owned() + &"a".repeat(64)),
        "--expected-generation",
        "1",
    ])
    .unwrap();
    let error = client
        .request("remove-once", invocation.method, invocation.params.clone())
        .unwrap_err();
    assert_eq!(
        arkdeck_cli::CliError::from_client(error, invocation.method).code,
        "outcomeUnknown"
    );
    let original = sent.borrow().clone();
    let frames = String::from_utf8(original.clone())
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["method"], "health");
    assert_eq!(frames[1]["method"], "runtime.tool.remove");
    assert!(matches!(
        client.request("retry-refused", invocation.method, invocation.params),
        Err(arkdeck_client::ClientError::ConnectionUnusable)
    ));
    assert_eq!(*sent.borrow(), original);
}

fn tool_list(options: &[&str]) -> Result<arkdeck_cli::Invocation, arkdeck_cli::CliError> {
    parse(
        &["runtime", "tool", "list"]
            .into_iter()
            .chain(options.iter().copied())
            .map(str::to_owned)
            .collect::<Vec<_>>(),
    )
}

#[test]
fn tool_list_uses_typed_page_size_and_keeps_cursor_opaque() {
    assert_eq!(
        tool_list(&[]).unwrap().params.unwrap(),
        json!({"pageSize":100}).as_object().unwrap().clone()
    );
    let value = tool_list(&["--page-size", "1000", "--cursor", "opaque"]).unwrap();
    assert_eq!(value.method, "runtime.tool.list");
    assert_eq!(
        value.params.unwrap(),
        json!({"pageSize":1000,"cursor":"opaque"})
            .as_object()
            .unwrap()
            .clone()
    );
    for options in [
        vec!["--page-size", "0"],
        vec!["--page-size", "1001"],
        vec!["--page-size", "1.0"],
        vec!["--tool", "sample"],
        vec!["--bundle", "sample"],
        vec!["--expected-generation", "1"],
    ] {
        assert_eq!(tool_list(&options).unwrap_err().code, "invalidOption");
    }
    assert!(tool_list(&["--help"]).unwrap().help);
}

#[test]
fn tool_list_keeps_readonly_connection_and_owner_error_policy() {
    use arkdeck_client::ClientError;
    use arkdeck_contract::WireError;
    for code in [
        "invalidInput",
        "invalidCursor",
        "resourceConflict",
        "recordUnreadable",
        "admissionDenied",
        "fileIdentityChanged",
        "ioFailure",
        "inputTooLarge",
        "operationUnavailable",
        "outcomeUnknown",
    ] {
        if arkdeck_contract::METHODS.contains(&"runtime.tool.list") {
            arkdeck_contract::validate_method_value("runtime.tool.list", "errorCode", &json!(code))
                .unwrap();
        }
        for details in [
            None,
            Some(json!({"phase":"bootstrapRegistryOwner","newDispatchCount":0})),
            Some(json!({"phase":"bootstrapRegistryOwner","newDispatchCount":1})),
            Some(json!({"phase":"otherOwner","newDispatchCount":0})),
        ] {
            let proof = details.as_ref().is_some_and(|d| {
                d["phase"] == "bootstrapRegistryOwner" && d["newDispatchCount"] == 0
            });
            let result = arkdeck_cli::CliError::from_client(
                ClientError::Remote(WireError {
                    code: code.into(),
                    message: "owner refused".into(),
                    details: details.as_ref().map(|d| d.as_object().unwrap().clone()),
                }),
                "runtime.tool.list",
            );
            assert_eq!(result.code, if proof { code } else { "internalError" });
            if proof && code == "fileIdentityChanged" {
                assert_eq!(result.exit_code(), 77);
            }
        }
    }
    assert_eq!(
        arkdeck_cli::CliError::from_client(
            ClientError::Transport(std::io::Error::from(std::io::ErrorKind::TimedOut)),
            "runtime.tool.list"
        )
        .code,
        "clientTimeout"
    );
    assert_eq!(
        arkdeck_cli::CliError::from_client(
            ClientError::Transport(std::io::Error::from(std::io::ErrorKind::ConnectionReset)),
            "runtime.tool.list"
        )
        .code,
        "runtimeUnavailable"
    );
}

#[test]
fn actual_tool_list_pages_validate_every_mixed_family_record_and_snapshot() {
    if !arkdeck_contract::METHODS.contains(&"runtime.tool.list") {
        let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
        assert_ne!(
            inputs["kind"], "candidate",
            "candidate must expose combined tool list"
        );
        return;
    }
    let path=std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/runtime.tool.list.jsonl");
    let corpus = std::fs::read_to_string(path).unwrap();
    let mut kinds = std::collections::BTreeSet::new();
    let mut pages = 0;
    for frame in corpus
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter(|frame| frame["ok"] == true)
    {
        let mut invocation = tool_list(&[]).unwrap();
        invocation.params = Some(frame["params"].as_object().unwrap().clone());
        invocation
            .params
            .as_mut()
            .unwrap()
            .entry("pageSize")
            .or_insert(json!(100));
        let page = &frame["result"];
        validate_bootstrap_response(&invocation, page).unwrap();
        pages += 1;
        for (key, bad) in [
            ("order", json!("bundleRef:asc")),
            ("snapshotRevision", json!("bad")),
            ("nextCursor", json!(17)),
            ("pageKind", json!("eventStream")),
        ] {
            let mut damaged = page.clone();
            damaged[key] = bad;
            assert_eq!(
                validate_bootstrap_response(&invocation, &damaged)
                    .unwrap_err()
                    .code,
                "recordUnreadable"
            );
        }
        for (index, row) in page["items"].as_array().unwrap().iter().enumerate() {
            kinds.insert(row["kind"].as_str().unwrap().to_owned());
            for (key, bad) in [
                ("generation", json!("0")),
                ("contentDigest", json!("invalid")),
                (
                    "contentRetained",
                    json!(!row["contentRetained"].as_bool().unwrap()),
                ),
                (
                    "toolRef",
                    json!("bundle:sha256:".to_owned() + &"0".repeat(64)),
                ),
            ] {
                let mut damaged = page.clone();
                damaged["items"][index][key] = bad;
                assert_eq!(
                    validate_bootstrap_response(&invocation, &damaged)
                        .unwrap_err()
                        .code,
                    "recordUnreadable"
                );
            }
        }
        if let Some(row) = page["items"].as_array().unwrap().first() {
            let mut duplicate = page.clone();
            duplicate["items"] = json!([row, row]);
            let mut roomy = invocation.clone();
            roomy
                .params
                .as_mut()
                .unwrap()
                .insert("pageSize".into(), json!(100));
            assert_eq!(
                validate_bootstrap_response(&roomy, &duplicate)
                    .unwrap_err()
                    .code,
                "recordUnreadable"
            );
            roomy.params.as_mut().unwrap().insert(
                "cursor".into(),
                json!("00000000-0000-0000-0000-000000000000.11111111-1111-1111-1111-111111111111"),
            );
            assert_eq!(
                validate_bootstrap_response(&roomy, page).unwrap_err().code,
                "recordUnreadable"
            );
        }
    }
    assert!(pages > 0);
    assert_eq!(
        kinds,
        std::collections::BTreeSet::from(["hdc".into(), "deveco".into()])
    );
}
