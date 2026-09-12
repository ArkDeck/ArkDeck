use arkdeck_cli::{parse, validate_read_only_response};
use serde_json::{Value, json};
#[test]
fn unary_events_argv_matches_current_swift_and_preserves_exclusive_cursor() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/current-cli-argv/job.events.json"
    ))
    .unwrap();
    for row in fixture["cases"].as_array().unwrap() {
        let args = row["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        let result = parse(&args);
        if row["name"] == "macosCompatibilityOption" && !cfg!(target_os = "macos") {
            assert_eq!(result.unwrap_err().code, "unsupportedOnPlatform");
        } else if row["expected"]["outcome"] == "failure" {
            assert_eq!(result.unwrap_err().code, row["expected"]["code"], "{row}");
        } else {
            assert_eq!(result.unwrap().command, "job.events");
        }
    }
    let args = [
        "job",
        "events",
        "--job",
        "job-a",
        "--after-cursor",
        "opaque",
        "--page-size",
        "12",
        "--timeout",
        "5s",
    ]
    .map(str::to_owned);
    let parsed = parse(&args).unwrap();
    assert_eq!(parsed.timeout_ms, Some(5000));
    assert_eq!(
        parsed.params,
        json!({"jobId":"job-a", "pageSize":12,"afterCursor":"opaque"})
            .as_object()
            .cloned()
    );
}
#[test]
fn native_event_pages_are_checked_before_emission() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.events.jsonl");
    let mut checked = 0;
    for line in std::fs::read_to_string(path).unwrap().lines() {
        let row: Value = serde_json::from_str(line).unwrap();
        if row["ok"] != true {
            continue;
        }
        let job = row["params"]["jobId"].as_str().unwrap();
        let mut parsed =
            parse(&["job".into(), "events".into(), "--job".into(), job.into()]).unwrap();
        parsed.params = row["params"].as_object().cloned();
        validate_read_only_response(&parsed, &row["result"]).unwrap();
        checked += 1;
        let mut broken = row["result"].clone();
        broken["snapshotRevision"] = json!("01");
        assert!(validate_read_only_response(&parsed, &broken).is_err());
        if !row["result"]["items"].as_array().unwrap().is_empty() {
            let mut broken = row["result"].clone();
            broken["items"][0]["data"]["jobId"] = json!("another");
            assert!(validate_read_only_response(&parsed, &broken).is_err());
            let mut broken = row["result"].clone();
            broken["items"][0]["data"]["payload"] = json!({"secret":"must not emit"});
            assert!(validate_read_only_response(&parsed, &broken).is_err());
        }
    }
    assert!(checked > 0);
}
