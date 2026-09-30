use arkdeck_cli::{parse, validate_bootstrap_request, validate_bootstrap_response};
use serde_json::{Value, json};
/// A daemon Bundle as this host spells an absolute local path, and paths it
/// refuses before any request: Swift's `/…` grammar on macOS, `X:\…` on
/// Windows.
#[cfg(not(windows))]
const SOURCE: &str = "/Source.app";
#[cfg(windows)]
const SOURCE: &str = r"C:\Source.app";
#[cfg(not(windows))]
const REFUSED_FILES: &[&str] = &[
    "relative.app",
    "/tmp/../Source.app",
    "/tmp/./Source.app",
    "/Source.app\0",
];
#[cfg(windows)]
const REFUSED_FILES: &[&str] = &[
    "relative.app",
    "/Source.app",
    r"C:\tmp\..\Source.app",
    r"C:\tmp\.\Source.app",
    "C:\\Source.app\0",
];
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
    let args = invocation(&["--kind", "daemon-bundle", "--file", SOURCE]).unwrap();
    assert_eq!(args.method, "runtime.bundle.register");
    assert_eq!(
        args.params.as_ref().unwrap(),
        json!({"kind":"daemon-bundle","file":SOURCE})
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
        vec!["--kind", "hdc", "--file", SOURCE],
        vec![
            "--kind",
            "daemon-bundle",
            "--file",
            SOURCE,
            "--digest",
            "caller",
        ],
        vec![
            "--kind",
            "daemon-bundle",
            "--file",
            SOURCE,
            "--expected-generation",
            "1",
        ],
    ] {
        assert_eq!(invocation(&options).unwrap_err().code, "invalidOption");
    }
    // Swift's parser takes any `--file`; its handler refuses a path that is
    // not absolute and canonical before any request, and so does this CLI.
    for file in REFUSED_FILES {
        let parsed = invocation(&["--kind", "daemon-bundle", "--file", file]).unwrap();
        assert_eq!(
            validate_bootstrap_request(&parsed).unwrap_err().code,
            "invalidInput"
        );
    }
    assert_eq!(
        invocation(&["--kind", "daemon-bundle"]).unwrap_err().code,
        "invalidOption"
    );
    assert!(invocation(&["--help"]).unwrap().help);
}
#[test]
fn actual_swift_fixture_receipts_keep_identity_and_map_invalid_receipts_to_unknown() {
    let args = invocation(&["--kind", "daemon-bundle", "--file", SOURCE]).unwrap();
    if !arkdeck_contract::METHODS.contains(&args.method) {
        return;
    }
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/runtime.bundle.register.jsonl");
    let frames = std::fs::read_to_string(path).unwrap();
    let mut successes = 0;
    for frame in frames
        .lines()
        .map(|line| hosted(serde_json::from_str::<Value>(line).unwrap()))
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

/// A recorded (macOS) Bootstrap record as this host's Runtime answers it: the
/// CLI checks that a record names its host's platform, so on Windows the
/// recorded `"platform": "macos"` reads `"windows"`; on macOS nothing changes.
fn hosted(mut value: Value) -> Value {
    fn host(value: &mut Value) {
        match value {
            Value::Object(map) => {
                if let Some(platform) = map.get_mut("platform")
                    && *platform == "macos"
                {
                    *platform = json!("windows");
                }
                map.values_mut().for_each(host);
            }
            Value::Array(items) => items.iter_mut().for_each(host),
            _ => {}
        }
    }
    if cfg!(windows) {
        host(&mut value);
    }
    value
}
