use arkdeck_cli::{parse, validate_bootstrap_response};
use serde_json::{Value, json};

#[test]
fn existing_bootstrap_argv_fixtures_keep_their_dispatch_contract() {
    for corpus in [
        include_str!("../../../tests/fixtures/current-cli-argv/runtime.tool.inspect.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/runtime.bundle.inspect.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/runtime.bundle.list.json"),
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
