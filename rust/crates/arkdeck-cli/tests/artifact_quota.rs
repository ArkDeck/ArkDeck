//! `artifact quota`: the current Swift argv.
use arkdeck_cli::parse;
use serde_json::Value;

#[test]
fn quota_argv_matches_current_swift() {
    let fixture: Value = arkdeck_cli::machine_contracts::argv_fixture("artifact.quota").unwrap();
    for row in fixture["cases"].as_array().unwrap() {
        let argv: Vec<String> = row["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap().to_owned())
            .collect();
        let result = parse(&argv);
        let expected = &row["expected"];
        if row["name"] == "macosCompatibilityOption" && !cfg!(target_os = "macos") {
            assert_eq!(result.unwrap_err().code, "unsupportedOnPlatform");
        } else if expected["outcome"] == "failure" {
            let error = result.unwrap_err();
            assert_eq!(
                (error.code, i64::from(error.exit_code())),
                (
                    expected["code"].as_str().unwrap(),
                    expected["exitCode"].as_i64().unwrap()
                ),
                "{row}"
            );
        } else {
            let invocation = result.unwrap();
            assert_eq!(invocation.command, "artifact.quota", "{row}");
            if expected["outcome"] == "dispatch" {
                // Swift sends the method without parameters.
                assert_eq!(invocation.params, None, "{row}");
                assert_eq!(invocation.timeout_ms, None);
            } else {
                assert!(invocation.help, "{row}");
            }
        }
    }
    let bounded: Vec<String> = ["artifact", "quota", "--timeout", "5m"]
        .into_iter()
        .map(str::to_owned)
        .collect();
    let invocation = parse(&bounded).unwrap();
    assert_eq!(invocation.timeout_ms, Some(300_000));
    assert_eq!(invocation.params, None);
}

#[test]
fn inventory_wait_is_local_bounded_and_discoverable() {
    use arkdeck_cli::{help_text, parse};
    for path in [
        vec!["runtime", "health"],
        vec!["runtime", "storage", "status"],
        vec!["artifact", "quota"],
    ] {
        let args = |extra: &[&str]| {
            path.iter()
                .chain(extra)
                .map(|s| (*s).to_owned())
                .collect::<Vec<_>>()
        };
        let original = parse(&args(&[])).unwrap();
        assert_eq!(original.timeout_ms, None);
        let bounded = parse(&args(&["--timeout", "5m"])).unwrap();
        assert_eq!(bounded.timeout_ms, Some(300_000));
        assert_eq!(bounded.method, original.method);
        assert_eq!(bounded.params, original.params);
        assert!(parse(&args(&["--help"])).unwrap().help);
        let help = help_text(&path.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>()).unwrap();
        assert!(help.contains("--timeout"));
        for duration in ["0s", "01s", "25h", "18446744073709551616h"] {
            assert_eq!(
                parse(&args(&["--timeout", duration])).unwrap_err().code,
                "invalidOption"
            );
        }
    }
}
