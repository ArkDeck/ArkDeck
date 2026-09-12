use arkdeck_cli::{parse, validate_bootstrap_request, validate_bootstrap_response};
use serde_json::{Value, json};
fn invocation(options: &[&str]) -> Result<arkdeck_cli::Invocation, arkdeck_cli::CliError> {
    parse(
        &["runtime", "bundle", "register"]
            .into_iter()
            .chain(options.iter().copied())
            .map(str::to_owned)
            .collect::<Vec<_>>(),
    )
}
#[test]
fn registration_only_sends_kind_and_file_and_keeps_published_method_gate() {
    let args = invocation(&["--kind", "daemon-bundle", "--file", "/Source.app"]).unwrap();
    assert_eq!(args.method, "runtime.bundle.register");
    assert_eq!(
        args.params.as_ref().unwrap(),
        json!({"kind":"daemon-bundle","file":"/Source.app"})
            .as_object()
            .unwrap()
    );
    if arkdeck_contract::METHODS.contains(&args.method) {
        validate_bootstrap_request(&args).unwrap();
    } else {
        assert_eq!(
            validate_bootstrap_request(&args).unwrap_err().code,
            "controlMethodUnavailable"
        );
    }
    for options in [
        vec![],
        vec!["--kind", "hdc", "--file", "/Source.app"],
        vec![
            "--kind",
            "daemon-bundle",
            "--file",
            "/Source.app",
            "--digest",
            "caller",
        ],
        vec![
            "--kind",
            "daemon-bundle",
            "--file",
            "/Source.app",
            "--expected-generation",
            "1",
        ],
    ] {
        assert_eq!(invocation(&options).unwrap_err().code, "invalidOption");
    }
    for file in [
        "relative.app",
        "/tmp/../Source.app",
        "/tmp/./Source.app",
        "/Source.app\0",
    ] {
        assert_eq!(
            invocation(&["--kind", "daemon-bundle", "--file", file])
                .unwrap_err()
                .code,
            "invalidInput"
        );
    }
    assert!(invocation(&["--help"]).unwrap().help);
}
#[test]
fn actual_swift_fixture_receipts_keep_identity_and_map_invalid_receipts_to_unknown() {
    let args = invocation(&["--kind", "daemon-bundle", "--file", "/Source.app"]).unwrap();
    if !arkdeck_contract::METHODS.contains(&args.method) {
        return;
    }
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/runtime.bundle.register.jsonl");
    let frames = std::fs::read_to_string(path).unwrap();
    let mut successes = 0;
    for frame in frames
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter(|row| row["ok"] == true)
    {
        successes += 1;
        validate_bootstrap_response(&args, &frame["result"]).unwrap();
        for (key, value) in [
            ("bundleRef", json!("bundle:sha256:bad")),
            ("contentDigest", json!("0".repeat(64))),
            ("generation", json!("2")),
            ("state", json!("removed")),
            ("contentRetained", json!(false)),
        ] {
            let mut invalid = frame["result"].clone();
            invalid[key] = value;
            assert_eq!(
                validate_bootstrap_response(&args, &invalid)
                    .unwrap_err()
                    .code,
                "outcomeUnknown"
            );
        }
    }
    assert!(successes > 0);
}
