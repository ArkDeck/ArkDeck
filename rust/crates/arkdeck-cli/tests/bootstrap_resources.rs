use arkdeck_cli::{parse, validate_bootstrap_response};
use serde_json::{Value, json};

#[test]
fn existing_bootstrap_argv_fixtures_keep_their_dispatch_contract() {
    for corpus in [
        include_str!("../../../tests/fixtures/current-cli-argv/runtime.tool.inspect.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/runtime.bundle.inspect.json"),
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
