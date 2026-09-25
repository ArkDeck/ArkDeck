//! `capability list` and `capability inspect`: the current Swift argv.
use arkdeck_cli::parse;
use serde_json::{Value, json};

fn argv(row: &Value) -> Vec<String> {
    row["argv"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap().to_owned())
        .collect()
}

fn check(command: &str, params: Option<Value>) {
    let fixture = arkdeck_cli::machine_contracts::argv_fixture(command).unwrap();
    for row in fixture["cases"].as_array().unwrap() {
        let result = parse(&argv(row));
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
            assert_eq!(invocation.command, command, "{row}");
            if expected["outcome"] == "dispatch" {
                assert_eq!(
                    invocation.params,
                    params.as_ref().and_then(Value::as_object).cloned(),
                    "{row}"
                );
                assert_eq!(invocation.timeout_ms, None);
            } else {
                assert!(invocation.help, "{row}");
            }
        }
    }
}

#[test]
fn list_argv_matches_current_swift() {
    check("capability.list", None);
}

#[test]
fn inspect_argv_matches_current_swift() {
    check(
        "capability.inspect",
        Some(json!({"capabilityId": "sample"})),
    );
}

#[test]
fn neither_takes_a_wait_bound() {
    for argv in [
        vec!["capability", "list", "--timeout", "5m"],
        vec![
            "capability",
            "inspect",
            "--capability",
            "CAP-RT-A",
            "--timeout",
            "5m",
        ],
    ] {
        let argv: Vec<String> = argv.into_iter().map(str::to_owned).collect();
        assert_eq!(parse(&argv).unwrap_err().code, "invalidOption", "{argv:?}");
    }
}
