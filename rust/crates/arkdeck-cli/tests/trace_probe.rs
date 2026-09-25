//! `arkdeck trace probe` as Swift's handler serves it: one `trace.probe` for
//! the exact `--target`, whose answer is emitted as the Runtime gave it. The
//! fake Runtime serves the answers Swift's daemon recorded
//! (`Fixtures/ControlFrames/trace.probe.jsonl`).
use arkdeck_cli::parse;

fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

#[test]
fn the_probe_takes_its_target_and_the_legacy_raw_document() {
    let invocation = parse(&args(&["trace", "probe", "--target", "TGT-1"])).unwrap();
    assert_eq!(
        (invocation.command, invocation.method),
        ("trace.probe", "trace.probe")
    );
    assert_eq!(
        invocation.params.unwrap()["targetId"],
        serde_json::json!("TGT-1")
    );
    // `--json`, which Swift's registry declares for this leaf, prints the raw
    // answer, as it does for `debug probe`; it still excludes `--output`.
    assert!(
        parse(&args(&["trace", "probe", "--target", "TGT-1", "--json"]))
            .unwrap()
            .legacy_json
    );
    let error = parse(&args(&[
        "trace", "probe", "--target", "TGT-1", "--json", "--output", "json",
    ]))
    .unwrap_err();
    assert_eq!(error.code, "invalidOption");
    // Without its target it is refused in Swift's registry words.
    let error = parse(&args(&["trace", "probe"])).unwrap_err();
    assert_eq!(
        (error.code, error.message.as_str(), error.command),
        (
            "invalidOption",
            "`trace probe` requires --target <target-id>",
            Some("trace.probe")
        )
    );
}

// The fake Runtime this leaf is driven against is a Unix socket.
#[cfg(target_os = "macos")]
mod support;

#[cfg(target_os = "macos")]
mod runtime {
    use super::support;
    use serde_json::{Value, json};

    /// Swift's daemon's recorded probe answer and the target it answered for.
    fn recorded() -> (String, Value) {
        let frame: Value = include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/trace.probe.jsonl"
        )
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .find(|frame| frame["ok"] == true)
        .expect("Swift recorded a probe answer");
        (
            frame["params"]["targetId"].as_str().unwrap().to_owned(),
            frame["result"].clone(),
        )
    }

    #[test]
    fn the_probe_sends_its_target_and_emits_the_runtimes_answer() {
        let (target, result) = recorded();
        let exchange = || {
            vec![(
                "trace.probe".to_owned(),
                json!({"targetId": target}),
                json!({"ok": true, "result": result}),
            )]
        };
        let (output, envelope) = support::run(&["trace", "probe", "--target", &target], exchange());
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        assert_eq!(envelope["command"], "trace.probe");
        assert_eq!(envelope["result"], result);
        // The human rendering is the same answer.
        let (output, _) = support::run(
            &["trace", "probe", "--target", &target, "--output", "human"],
            exchange(),
        );
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(
            serde_json::from_slice::<Value>(&output.stdout).unwrap(),
            result
        );
    }

    #[test]
    fn a_refusal_is_the_runtimes_own() {
        let (output, envelope) = support::run(
            &["trace", "probe", "--target", "TGT-missing"],
            vec![(
                "trace.probe".to_owned(),
                json!({"targetId": "TGT-missing"}),
                json!({"ok": false, "error": {"code": "notFound", "message": "target TGT-missing is not adopted"}}),
            )],
        );
        assert_eq!(output.status.code(), Some(65), "{envelope}");
        assert_eq!(envelope["command"], "trace.probe");
        assert_eq!(envelope["error"]["code"], "resourceNotFound");
        assert_eq!(
            envelope["error"]["message"],
            "target TGT-missing is not adopted"
        );
    }
}
