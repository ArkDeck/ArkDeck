//! Swift's CLI answers to the Import arguments it leaves to the Runtime or
//! refuses itself (TASK-XPA-013, X6, X7), as Swift's
//! `ImportAppRefusalOracleContractTests` recorded them
//! (`rust/tests/fixtures/import-app-refusal-oracle`, "cli"), replayed through
//! this CLI's binary against a fake Runtime answering as Swift's daemon did:
//! the exit status, the machine output and the standard error.
#![cfg(target_os = "macos")]
mod support;

use serde_json::{Value, json};
use std::os::unix::fs::DirBuilderExt;

fn case(name: &str) -> Value {
    let oracle: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/import-app-refusal-oracle/cases.json"
    ))
    .unwrap();
    oracle["cli"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["case"] == name)
        .unwrap_or_else(|| panic!("no oracle case {name}"))
        .clone()
}

/// The recorded argv, with this run's Target and file for the names the
/// oracle gave them, and a request identity this test can name.
fn argv(case: &Value, target: &str, file: &str) -> Vec<String> {
    let mut argv: Vec<String> = case["argv"]
        .as_array()
        .unwrap()
        .iter()
        .map(|arg| match arg.as_str().unwrap() {
            "$targetId" => target.to_owned(),
            "$file" => file.to_owned(),
            "$liveImportId" => "imp-00000000-0000-4000-8000-000000000001".to_owned(),
            other => other.to_owned(),
        })
        .collect();
    argv.extend(["--control-request-id".to_owned(), "oracle-cli".to_owned()]);
    argv
}

/// Swift's machine output, with its per-run identity as this run's.
fn printed(case: &Value) -> Value {
    let mut stdout = case["stdout"].clone();
    if stdout.is_object() {
        stdout["meta"]["controlRequestId"] = json!("oracle-cli");
    }
    stdout
}

fn replay(name: &str, target: &str, file: &str, replies: Vec<(String, Value, Value)>) {
    let case = case(name);
    let args = argv(&case, target, file);
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let (output, envelope) = support::run(&args, replies);
    assert_eq!(
        output.status.code().map(i64::from),
        case["exitStatus"].as_i64(),
        "{name}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(envelope, printed(&case), "{name}");
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        case["stderr"].as_str().unwrap(),
        "{name}"
    );
}

fn owner_refusal(code: &str, message: &str) -> Value {
    json!({"ok":false,"error":{"code":code,"message":message,
        "details":{"phase":"importOwner","newDispatchCount":0}}})
}

/// X6: the registry requires exactly one selector, in Swift's words, before
/// any request.
#[test]
fn inspect_without_exactly_one_selector_is_refused_by_the_registry_as_swift_s() {
    for name in ["cli.inspect.noSelector", "cli.inspect.bothSelectors"] {
        replay(name, "", "", vec![]);
    }
}

/// X6: the target and the cursor go to the Runtime as given, and its
/// refusal is the answer.
#[test]
fn list_options_the_runtime_judges_reach_it_as_given() {
    replay(
        "cli.list.targetInvalid",
        "",
        "",
        vec![(
            "artifact.import.list".into(),
            json!({"target":"../target"}),
            owner_refusal("invalidInput", "Import filter is invalid"),
        )],
    );
    replay(
        "cli.list.cursorEmpty",
        "",
        "",
        vec![(
            "artifact.import.list".into(),
            json!({"cursor":""}),
            owner_refusal("invalidCursor", "invalid Import cursor"),
        )],
    );
}

/// X7: a native library whose file name is no lib*.so is Swift's plain
/// usage failure: its words on stderr, nothing on stdout, exit 64.
#[test]
fn an_unsafe_native_library_name_is_swift_s_plain_usage_failure() {
    // The adopted Target the oracle named `$targetId`, as Swift's daemon
    // shows it.
    let shown = include_str!(
        "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/target.show.jsonl"
    )
    .lines()
    .map(|line| serde_json::from_str::<Value>(line).unwrap())
    .find(|frame| frame["ok"] == true)
    .unwrap();
    let target = shown["params"]["targetId"].as_str().unwrap().to_owned();
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "cli-native-name-{:032x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    ));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&root)
        .unwrap();
    let file = root.join("fixture.bin");
    std::fs::write(&file, [0x7f; 64]).unwrap();
    replay(
        "cli.nativeLibrary.unsafeName",
        &target,
        file.to_str().unwrap(),
        vec![
            (
                "artifact.import.inspect".into(),
                json!({"importRequestId":"oracle-cli-native"}),
                owner_refusal("resourceNotFound", "Import does not exist"),
            ),
            (
                "target.show".into(),
                json!({"targetId":target}),
                json!({"ok":true,"result":shown["result"]}),
            ),
        ],
    );
    std::fs::remove_dir_all(&root).unwrap();
}
