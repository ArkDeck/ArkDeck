use arkdeck_cli::{agent_exit, read_console_challenge, validate_control_action_result};
use serde_json::{Value, json};
use std::io::Cursor;

fn frames() -> Vec<Value> {
    include_str!("../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/human-action.resume.jsonl")
        .lines().map(|line| serde_json::from_str(line).unwrap()).collect()
}
fn challenge() -> Value {
    frames()
        .into_iter()
        .find(|frame| frame["result"]["schemaVersion"] == "arkdeck.impact-approval-challenge/1")
        .unwrap()
}
fn terminal(state: &str) -> Value {
    frames()
        .into_iter()
        .find(|frame| {
            frame["result"]["schemaVersion"] == "arkdeck.control-action/1"
                && frame["result"]["state"] == state
        })
        .unwrap()["result"]
        .clone()
}

#[test]
fn recorded_preview_is_complete_and_bound_before_input() {
    let frame = challenge();
    let expected = frame["result"]["challenge"].as_str().unwrap();
    let input = format!("{expected}\n");
    let mut output = Vec::new();
    assert_eq!(
        read_console_challenge(&frame["result"], true, &mut Cursor::new(input), &mut output)
            .unwrap(),
        expected
    );
    let output = String::from_utf8(output).unwrap();
    let preview_start = output.find('{').unwrap();
    let preview_end = output
        .find("\nType this one-time challenge exactly:")
        .unwrap();
    let review: Value = serde_json::from_str(&output[preview_start..preview_end]).unwrap();
    assert_eq!(
        review["preview"],
        frame["result"]["controlAction"]["preview"]
    );
    assert_eq!(
        review["controlActionId"],
        frame["result"]["controlAction"]["controlActionId"]
    );
    // The challenge binds the pre-issuance generation, while its returned
    // action has already persisted that challenge. These need not be equal.
    assert_ne!(
        frame["result"]["binding"]["generation"],
        review["generation"]
    );
    for pointer in [
        "/binding/controlActionId",
        "/binding/humanActionId",
        "/binding/previewId",
        "/binding/previewDigest",
        "/controlAction/preview/endpoint",
        "/controlAction/preview/previewDigest",
        "/challenge",
    ] {
        let mut invalid = frame["result"].clone();
        *invalid.pointer_mut(pointer).unwrap() = json!("rebound");
        let mut input = Cursor::new(expected.as_bytes());
        let mut output = Vec::new();
        assert_eq!(
            read_console_challenge(&invalid, true, &mut input, &mut output)
                .unwrap_err()
                .code,
            "recordUnreadable",
            "{pointer}"
        );
        assert_eq!(input.position(), 0);
        assert!(output.is_empty());
    }
}

#[test]
fn console_read_is_bounded_exact_and_refuses_redirected_input() {
    let frame = challenge();
    let expected = frame["result"]["challenge"].as_str().unwrap();
    for (input, code) in [
        (Vec::new(), "admissionDenied"),
        (b"wrong\n".to_vec(), "admissionDenied"),
        (vec![b'A'; 1000], "admissionDenied"),
        (b"\x1b[2J\n".to_vec(), "invalidInput"),
        (b"\x7f\n".to_vec(), "invalidInput"),
        (b"\xff\n".to_vec(), "admissionDenied"),
    ] {
        let mut input = Cursor::new(input);
        assert_eq!(
            read_console_challenge(&frame["result"], true, &mut input, &mut Vec::new())
                .unwrap_err()
                .code,
            code
        );
        assert!(input.position() <= 65);
    }
    let mut input = Cursor::new(expected.as_bytes());
    let mut output = Vec::new();
    assert_eq!(
        read_console_challenge(&frame["result"], false, &mut input, &mut output)
            .unwrap_err()
            .code,
        "recordUnreadable"
    );
    assert_eq!(input.position(), 0);
    assert!(output.is_empty());
    for ending in ["\n", "\r", ""] {
        assert_eq!(
            read_console_challenge(
                &frame["result"],
                true,
                &mut Cursor::new(format!("{expected}{ending}")),
                &mut Vec::new()
            )
            .unwrap(),
            expected
        );
    }
}

#[test]
fn control_action_outcomes_preserve_their_exit_and_projection() {
    for (state, exit) in [
        ("succeeded", None),
        ("failed", Some(1)),
        ("outcomeUnknown", Some(75)),
    ] {
        let result = terminal(state);
        validate_control_action_result(&result).unwrap();
        assert_eq!(agent_exit(&result).map(|(code, _)| code), exit);
    }
    let mut result = terminal("succeeded");
    result["dispatchCount"] = json!(2);
    assert_eq!(
        validate_control_action_result(&result).unwrap_err().code,
        "recordUnreadable"
    );
    for (count, code) in [(0, 77), (1, 75)] {
        result["dispatchCount"] = json!(count);
        result["state"] = json!("dispatching");
        assert_eq!(agent_exit(&result).unwrap().0, code);
    }
}

#[cfg(target_os = "macos")]
fn pty_run(input: &[u8], state: &str, timeout: bool, drop_reply: bool) -> Value {
    use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
    use std::io::Write;
    use std::process::{Command, Stdio};
    let frame = challenge();
    let config = json!({
        "binary": env!("CARGO_BIN_EXE_arkdeck"),
        "health": {"status":"ok","protocolVersion":PROTOCOL_VERSION,
            "contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,
            "providers":[],"publishedMethods":METHODS},
        "params":frame["params"],"challenge":frame["result"],"terminal":terminal(state),
        "input":input,"drop_reply":drop_reply,
        "timeout":if timeout { Some("250ms") } else { None },
        "delay_ms":if timeout { 350 } else { 0 },
    });
    let mut child = Command::new("/usr/bin/python3")
        .args(["-c", include_str!("support/console_pty.py")])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(serde_json::to_string(&config).unwrap().as_bytes())
        .unwrap();
    let result = child.wait_with_output().unwrap();
    assert!(
        result.status.success(),
        "{} {}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    serde_json::from_slice(&result.stdout).unwrap()
}

#[cfg(target_os = "macos")]
#[test]
fn actual_cli_uses_terminal_input_once_and_preserves_terminal_outcomes() {
    let frame = challenge();
    let expected = frame["result"]["challenge"].as_str().unwrap();
    for (state, exit) in [("succeeded", 0), ("failed", 1), ("outcomeUnknown", 75)] {
        let result = pty_run(format!("{expected}\n").as_bytes(), state, false, false);
        assert_eq!(result["exit"], exit, "{result}");
        assert_eq!(result["frames"].as_array().unwrap().len(), 2, "{result}");
        assert_eq!(result["frames"][0]["params"], frame["params"]);
        let mut params = frame["params"].clone();
        params["challengeResponse"] = json!(expected);
        assert_eq!(result["frames"][1]["params"], params);
        let stdout = result["stdout"].as_str().unwrap();
        let envelope: Value = serde_json::from_str(stdout).unwrap();
        assert_eq!(envelope["result"]["state"], state, "{envelope}");
        assert!(!stdout.contains(expected));
        assert!(
            result["stderr"]
                .as_str()
                .unwrap()
                .contains("Type this one-time challenge exactly:")
        );
    }
}

#[cfg(target_os = "macos")]
#[test]
fn actual_cli_never_resumes_after_wrong_input_or_expired_deadline_and_never_replays_loss() {
    let expected = challenge()["result"]["challenge"]
        .as_str()
        .unwrap()
        .to_owned();
    for (input, exit) in [
        (b"wrong\n".to_vec(), 77),
        (vec![b'A'; 1000], 77),
        (b"\x1b\n".to_vec(), 65),
    ] {
        let result = pty_run(&input, "succeeded", false, false);
        assert_eq!(result["exit"], exit, "{result}");
        assert_eq!(result["frames"].as_array().unwrap().len(), 1);
    }
    let result = pty_run(format!("{expected}\n").as_bytes(), "succeeded", true, false);
    assert_eq!(result["exit"], 75, "{result}");
    assert_eq!(result["frames"].as_array().unwrap().len(), 1);
    let result = pty_run(format!("{expected}\n").as_bytes(), "succeeded", false, true);
    assert_eq!(result["exit"], 75, "{result}");
    assert_eq!(result["frames"].as_array().unwrap().len(), 2);
    let envelope: Value = serde_json::from_str(result["stdout"].as_str().unwrap()).unwrap();
    assert_eq!(envelope["error"]["code"], "outcomeUnknown");
}

#[cfg(unix)]
mod support;

#[cfg(unix)]
#[test]
fn actual_cli_refuses_a_challenge_without_terminal_input() {
    let frame = challenge();
    let (output, envelope) = support::run(
        &[
            "human-action",
            "resume",
            "--human-action",
            frame["params"]["humanAction"].as_str().unwrap(),
            "--resume-reference",
            frame["params"]["resumeReference"].as_str().unwrap(),
        ],
        vec![(
            "human-action.resume".into(),
            frame["params"].clone(),
            json!({"ok":true,"result":frame["result"]}),
        )],
    );
    assert_eq!(
        output.status.code(),
        Some(if cfg!(target_os = "macos") { 2 } else { 75 })
    );
    assert_eq!(
        envelope["error"]["code"],
        if cfg!(target_os = "macos") {
            "recordUnreadable"
        } else {
            "humanActionRequired"
        }
    );
    assert!(!String::from_utf8_lossy(&output.stderr).contains("Type this one-time challenge"));
}
