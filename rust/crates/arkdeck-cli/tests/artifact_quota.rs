//! `artifact quota`: the current Swift argv.
use arkdeck_cli::parse;
use serde_json::Value;

#[test]
fn quota_argv_matches_current_swift() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/current-cli-argv/artifact.quota.json"
    ))
    .unwrap();
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
    assert_eq!(parse(&bounded).unwrap_err().code, "invalidOption");
}
