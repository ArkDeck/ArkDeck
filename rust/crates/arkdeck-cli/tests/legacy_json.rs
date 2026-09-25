//! The legacy `--json` rendering, as Swift's CLI writes it (CLI spec §12).
//!
//! The oracle (`rust/tests/fixtures/legacy-json`, recorded by
//! `CLILegacyJSONOracleContractTests`) holds Swift's `legacyDocument` bytes for
//! values that cover the format, and its `legacyFailure` documents. Every leaf
//! Swift's registry declares `--json` on takes it here too. Its answer, a
//! refusal after the parse and a refusal Swift's handler would make are each
//! that one document on stdout. A refusal Swift's parser makes stays prose on
//! stderr.
use arkdeck_cli::{CliError, legacy_document, legacy_failure, legacy_refusal, parse};
use serde_json::Value;
use std::path::Path;
use std::process::Command;

const ORACLE: &str = include_str!("../../../tests/fixtures/legacy-json/cases.json");

fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

#[test]
fn each_value_is_rendered_as_swifts_legacy_document() {
    let oracle: Value = serde_json::from_str(ORACLE).unwrap();
    let documents = oracle["documents"].as_array().unwrap();
    assert!(documents.len() >= 7);
    for case in documents {
        assert_eq!(
            String::from_utf8(legacy_document(&case["value"])).unwrap(),
            case["document"].as_str().unwrap(),
            "{}",
            case["name"]
        );
    }
    for case in oracle["failures"].as_array().unwrap() {
        // A code the registry names; the test keeps it for the process.
        let code: &'static str =
            Box::leak(case["code"].as_str().unwrap().to_owned().into_boxed_str());
        let error = CliError::new(code, case["message"].as_str().unwrap());
        assert_eq!(
            String::from_utf8(legacy_document(&legacy_failure(&error))).unwrap(),
            case["document"].as_str().unwrap(),
            "{code}"
        );
    }
}

/// Every copied Swift argv fixture's valid invocation, with `--json` added:
/// taken exactly where Swift's registry declares it for that leaf, and never
/// beside `--output`.
#[test]
fn every_leaf_takes_json_exactly_where_swifts_registry_declares_it() {
    let registry: Value =
        serde_json::from_str(include_str!("../src/command_registry.json")).unwrap();
    let declares = |command: &str| {
        registry["commands"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["command"] == command)
            .is_some_and(|entry| {
                entry["options"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|option| option["name"] == "--json")
            })
    };
    let directory =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/current-cli-argv");
    let (mut taken, mut refused) = (0, 0);
    for entry in std::fs::read_dir(directory).unwrap() {
        let fixture: Value =
            serde_json::from_slice(&std::fs::read(entry.unwrap().path()).unwrap()).unwrap();
        let command = fixture["command"].as_str().unwrap();
        let Some(valid) = fixture["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|case| case["name"] == "valid" && case["expected"]["outcome"] == "dispatch")
        else {
            continue;
        };
        let mut argv: Vec<String> = valid["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|argument| argument.as_str().unwrap().to_owned())
            .collect();
        if argv.iter().any(|argument| argument == "--output") {
            continue;
        }
        argv.push("--json".into());
        if declares(command) {
            let invocation = parse(&argv).unwrap_or_else(|error| {
                panic!("{command} refused --json: {} {}", error.code, error.message)
            });
            assert!(invocation.legacy_json, "{command}");
            argv.extend(["--output".into(), "json".into()]);
            assert_eq!(parse(&argv).unwrap_err().code, "invalidOption", "{command}");
            taken += 1;
        } else {
            assert_eq!(parse(&argv).unwrap_err().code, "invalidOption", "{command}");
            refused += 1;
        }
    }
    assert!(taken > 120, "{taken} leaves took --json");
    assert!(refused >= 1, "{refused} leaves refused it");
}

#[test]
fn a_refusal_swifts_handler_makes_is_the_legacy_document_and_its_parsers_is_prose() {
    // Swift's registry accepts the opaque `--job`; its handler refuses the
    // identity, in the session's legacy rendering, before any connection.
    let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(["job", "status", "--job", "bad:id", "--json"])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(65));
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "{\n  \"error\" : {\n    \"code\" : \"invalidInput\",\n    \"message\" : \"an exact Job identity is required\"\n  }\n}\n"
    );
    assert!(output.stderr.is_empty());
    // Swift's registry refuses a missing `--job` in prose on stderr.
    let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(["job", "status", "--json"])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(64));
    assert!(output.stdout.is_empty());
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        "arkdeck: `job status` requires --job <job-id>\n"
    );
    // A leaf the registry declares no `--json` for refuses it.
    assert_eq!(
        parse(&args(&["debug", "template", "list", "--json"]))
            .unwrap_err()
            .code,
        "invalidOption"
    );
}

/// A refusal this parser makes where Swift's registry accepts the argv is the
/// legacy document too: Swift's handler would have answered there, in the
/// session's rendering. A leaf this CLI does not serve yet is such a refusal,
/// as under `--output json` it is an envelope; so is `--socket` off macOS.
#[test]
fn a_refusal_this_parser_makes_where_swifts_registry_accepts_is_the_legacy_document() {
    assert!(legacy_refusal(&args(&[
        "job", "status", "--job", "J", "--json"
    ])));
    assert!(!legacy_refusal(&args(&["job", "status", "--json"])));
    assert!(!legacy_refusal(&args(&["job", "status", "--job", "J"])));
    let registry: Value =
        serde_json::from_str(include_str!("../src/command_registry.json")).unwrap();
    // The first leaf declaring `--json` and no required option that this CLI
    // does not serve yet. Once every leaf is served, none is left to try.
    let unserved = registry["commands"]
        .as_array()
        .unwrap()
        .iter()
        .find_map(|entry| {
            let options = entry["options"].as_array().unwrap();
            if !options.iter().any(|option| option["name"] == "--json")
                || options.iter().any(|option| option["required"] == true)
            {
                return None;
            }
            let mut argv: Vec<String> = entry["path"]
                .as_array()
                .unwrap()
                .iter()
                .map(|segment| segment.as_str().unwrap().to_owned())
                .collect();
            argv.push("--json".into());
            let error = parse(&argv).err()?;
            (error.code == "invalidCommand" && legacy_refusal(&argv)).then_some((argv, error))
        });
    if let Some((argv, error)) = unserved {
        let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(&argv)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(64), "{argv:?}");
        assert_eq!(
            output.stdout,
            legacy_document(&legacy_failure(&error)),
            "{argv:?}"
        );
        assert!(output.stderr.is_empty(), "{argv:?}");
    }
    #[cfg(not(target_os = "macos"))]
    {
        let argv = args(&["job", "status", "--job", "J", "--socket", "/x", "--json"]);
        let error = parse(&argv).unwrap_err();
        assert_eq!(error.code, "unsupportedOnPlatform");
        let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(&argv)
            .output()
            .unwrap();
        assert_eq!(output.stdout, legacy_document(&legacy_failure(&error)));
        assert!(output.stderr.is_empty());
    }
}

// The fake Runtime these leaves are driven against is a Unix socket.
#[cfg(target_os = "macos")]
mod support;

#[cfg(target_os = "macos")]
mod runtime {
    use super::support;
    use arkdeck_cli::legacy_document;
    use serde_json::{Value, json};

    /// A status Swift's daemon recorded, in `state`.
    fn status(state: &str) -> Value {
        include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.status.jsonl"
        )
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .find(|frame| frame["ok"] == true && frame["result"]["state"] == state)
        .unwrap_or_else(|| panic!("Swift recorded a {state} status"))["result"]
            .clone()
    }

    fn read(status: &Value) -> Vec<(String, Value, Value)> {
        vec![(
            "job.status".to_owned(),
            json!({"jobId": status["jobId"]}),
            json!({"ok": true, "result": status}),
        )]
    }

    #[test]
    fn a_result_and_a_refusal_are_each_one_legacy_document() {
        let succeeded = status("succeeded");
        let job = succeeded["jobId"].as_str().unwrap();
        let (output, _) =
            support::run(&["job", "status", "--job", job, "--json"], read(&succeeded));
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&legacy_document(&succeeded))
        );
        // The Runtime's refusal: its code and words, on stdout, nothing else.
        let (output, _) = support::run(
            &["job", "status", "--job", job, "--json"],
            vec![(
                "job.status".to_owned(),
                json!({"jobId": job}),
                json!({"ok": false, "error": {"code": "notFound", "message": "no such job"}}),
            )],
        );
        assert_eq!(output.status.code(), Some(65));
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "{\n  \"error\" : {\n    \"code\" : \"resourceNotFound\",\n    \"message\" : \"no such job\"\n  }\n}\n"
        );
        assert!(output.stderr.is_empty());
    }

    #[test]
    fn a_wait_prints_only_the_settled_status_and_exits_by_it() {
        let failed = status("failed");
        let job = failed["jobId"].as_str().unwrap();
        let (output, _) = support::run(&["job", "wait", "--job", job, "--json"], read(&failed));
        assert_eq!(output.status.code(), Some(1));
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&legacy_document(&failed))
        );
        // The terminal state is one diagnostic line on stderr, not a second
        // document. Swift's line names the family (`arkdeck job: …`); this
        // CLI's prefix is the one it writes in every mode, a gap of its own.
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(stderr.lines().count(), 1, "{stderr}");
        assert!(
            stderr.ends_with(": job terminal state is failed\n"),
            "{stderr}"
        );
    }
}
