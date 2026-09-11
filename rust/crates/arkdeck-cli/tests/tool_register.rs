use arkdeck_cli::{parse, validate_bootstrap_request, validate_bootstrap_response};
use serde_json::{Value, json};
fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|s| (*s).into()).collect()
}
fn invocation(root: &str) -> arkdeck_cli::Invocation {
    parse(&args(&[
        "runtime", "tool", "register", "--kind", "deveco", "--root", root,
    ]))
    .unwrap()
}
fn supported() -> bool {
    let available = arkdeck_contract::METHODS.contains(&"runtime.tool.register");
    let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
    if inputs["kind"] == "candidate" {
        assert!(
            available,
            "candidate must include actual DevEco registration RPC"
        );
    }
    available
}
fn recordings() -> Vec<Value> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/runtime.tool.register.jsonl");
    std::fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|s| serde_json::from_str(s).unwrap())
        .collect()
}
#[test]
fn current_argv_is_retained_with_rust_hdc_transport_support() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/current-cli-argv/runtime.tool.register.json"
    ))
    .unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let argv: Vec<String> = case["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().into())
            .collect();
        let parsed = parse(&argv);
        if !cfg!(target_os = "macos") && argv.iter().any(|v| v == "--socket") {
            assert_eq!(parsed.unwrap_err().code, "unsupportedOnPlatform");
        } else if argv.windows(2).any(|p| p == ["--kind", "hdc"])
            && (argv.iter().any(|v| v == "--socket") || case["name"] == "valid")
        {
            // Swift's parser defers the missing file to its local handler;
            // Rust rejects it before contacting the Runtime.
            assert_eq!(parsed.unwrap_err().code, "invalidInput");
        } else if case["expected"]["outcome"] == "failure" {
            assert_eq!(parsed.unwrap_err().code, case["expected"]["code"], "{case}");
        } else {
            assert_eq!(parsed.unwrap().command, "runtime.tool.register");
        }
    }
}
#[test]
fn paths_match_swift_local_grammar_and_request_is_closed_before_connect() {
    for root in [
        "/Applications/DevEco-Studio.app/Contents",
        "/tmp/a b/",
        "//tmp//root",
    ] {
        let parsed = invocation(root);
        assert_eq!(
            Value::Object(parsed.params.clone().unwrap()),
            json!({"kind":"deveco","root":root})
        );
        if supported() {
            validate_bootstrap_request(&parsed).unwrap();
        } else {
            assert_eq!(
                validate_bootstrap_request(&parsed).unwrap_err().code,
                "controlMethodUnavailable"
            );
        }
    }
    for root in [
        "relative",
        "~/root",
        "file:///tmp/root",
        "/tmp/../root",
        "/tmp/./root",
        "/tmp/\0root",
    ] {
        assert_eq!(
            parse(&args(&[
                "runtime", "tool", "register", "--kind", "deveco", "--root", root
            ]))
            .unwrap_err()
            .code,
            "invalidInput"
        );
    }
    for extra in [
        ["--file", "/tmp/file"],
        ["--tool", "tool-ref"],
        ["--kind", "deveco"],
    ] {
        let mut argv = args(&[
            "runtime",
            "tool",
            "register",
            "--kind",
            "deveco",
            "--root",
            "/tmp/root",
        ]);
        argv.extend(args(&extra));
        assert!(parse(&argv).is_err());
    }
    if supported() {
        let mut parsed = invocation("/tmp/root");
        parsed
            .params
            .as_mut()
            .unwrap()
            .insert("extra".into(), json!(true));
        assert!(validate_bootstrap_request(&parsed).is_err());
    }
}
#[test]
fn actual_registration_projection_has_content_identity_without_selection() {
    if !supported() {
        return;
    }
    let mut count = 0;
    for frame in recordings()
        .into_iter()
        .filter(|v| v["ok"] == true && v["params"]["kind"] == "deveco")
    {
        let parsed = invocation(frame["params"]["root"].as_str().unwrap());
        validate_bootstrap_request(&parsed).unwrap();
        validate_bootstrap_response(&parsed, &frame["result"]).unwrap();
        count += 1;
        for (key, value) in [
            ("kind", json!("hdc")),
            ("state", json!("removed")),
            ("generation", json!("2")),
            ("selected", json!(true)),
            ("contentRetained", json!(true)),
            ("source", json!("managedCopy")),
            ("contentDigest", json!("0".repeat(64))),
            ("root", json!("/leaked/path")),
        ] {
            let mut bad = frame["result"].clone();
            bad[key] = value;
            assert_eq!(
                validate_bootstrap_response(&parsed, &bad).unwrap_err().code,
                "outcomeUnknown",
                "{key}"
            );
        }
    }
    assert!(count > 0, "actual Swift registration success is required");
}
#[cfg(target_os = "macos")]
mod endpoint {
    use super::*;
    use arkdeck_contract::{
        CATALOG_DIGEST, CONTRACT_IDENTITY, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, METHODS,
        PROTOCOL_VERSION, encode_frame,
    };
    use arkdeck_platform::{LocalEndpoint, LocalListener, read_frame};
    use std::{
        io::{BufReader, Read, Write},
        os::unix::fs::DirBuilderExt,
    };
    fn directory() -> std::path::PathBuf {
        let name = arkdeck_platform::random_bytes::<8>()
            .unwrap()
            .iter()
            .map(|v| format!("{v:02x}"))
            .collect::<String>();
        let path = std::path::PathBuf::from(format!("/private/tmp/cli-register-{name}"));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .unwrap();
        path
    }
    fn command(root: &str, socket: &std::path::Path) -> std::process::Command {
        command_kind("deveco", root, socket)
    }
    fn command_kind(kind: &str, root: &str, socket: &std::path::Path) -> std::process::Command {
        let mut command = std::process::Command::new(env!("CARGO_BIN_EXE_arkdeck"));
        command
            .args([
                "runtime",
                "tool",
                "register",
                "--kind",
                kind,
                if kind == "hdc" { "--file" } else { "--root" },
                root,
                "--output",
                "json",
                "--control-request-id",
                "register-cli",
                "--socket",
            ])
            .arg(socket);
        command
    }
    #[test]
    fn unpublished_registration_opens_no_connection() {
        if supported() {
            return;
        }
        let dir = directory();
        let path = dir.join("socket");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        listener.set_nonblocking(true).unwrap();
        let output = command("/fixture/DevEco.app/Contents", &path)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(69));
        let doc: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(doc["error"]["code"], "controlMethodUnavailable");
        assert!(doc.get("result").is_none());
        assert!(matches!(listener.accept(),Err(e) if e.kind()==std::io::ErrorKind::WouldBlock));
        drop(listener);
        std::fs::remove_file(path).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
    fn run(root: &str, response: Option<Value>) -> (std::process::Output, Vec<Value>) {
        run_kind("deveco", root, response)
    }
    fn run_kind(
        kind: &str,
        root: &str,
        response: Option<Value>,
    ) -> (std::process::Output, Vec<Value>) {
        let dir = directory();
        let path = dir.join("socket");
        let mut listener = LocalListener::bind(&LocalEndpoint::new(&path)).unwrap();
        let server = std::thread::spawn(move || {
            let mut stream = BufReader::new(listener.accept().unwrap());
            stream
                .get_ref()
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
            let mut requests = Vec::new();
            for result in [
                Some(
                    json!({"id":"health","ok":true,"result":{"status":"ok","protocolVersion":PROTOCOL_VERSION,"contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,"providers":[],"publishedMethods":METHODS}}),
                ),
                response,
            ] {
                requests.push(
                    serde_json::from_slice::<Value>(
                        &read_frame(&mut stream, MAX_REQUEST_BYTES).unwrap(),
                    )
                    .unwrap(),
                );
                if let Some(result) = result {
                    stream
                        .get_mut()
                        .write_all(&encode_frame(&result, MAX_RESPONSE_BYTES).unwrap())
                        .unwrap();
                } else {
                    return requests;
                }
            }
            let mut extra = Vec::new();
            stream.read_to_end(&mut extra).unwrap();
            assert!(extra.is_empty(), "registration replayed");
            requests
        });
        let output = command_kind(kind, root, &path).output().unwrap();
        let requests = server.join().unwrap();
        std::fs::remove_dir(dir).unwrap();
        (output, requests)
    }
    #[test]
    fn actual_owner_refusals_preserve_failure_and_never_retry_registration() {
        if !supported() {
            return;
        }
        let mut count = 0;
        for frame in recordings().into_iter().filter(|v| v["ok"] == false) {
            let (output, requests) = run(
                "/fixture/DevEco.app/Contents",
                Some(json!({"id":"register-cli", "ok":false,"error":frame["error"]})),
            );
            assert!(!output.status.success());
            assert_eq!(requests.len(), 2);
            let doc: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(doc["ok"], false);
            assert!(doc.get("result").is_none());
            let code = frame["error"]["code"].as_str().unwrap();
            let expected = match code {
                "invalidParams" => "invalidInput",
                "unknownMethod" => "controlMethodUnavailable",
                "internalError" => "internalError",
                other => other,
            };
            assert_eq!(doc["error"]["code"], expected, "{frame}");
            count += 1;
        }
        assert!(count > 0, "actual owner refusal recordings are required");
    }

    #[test]
    fn real_producer_responses_are_one_typed_request_and_lost_reply_is_unknown() {
        if !supported() {
            return;
        }
        for frame in recordings()
            .into_iter()
            .filter(|v| v["ok"] == true && v["params"]["kind"] == "deveco")
        {
            let root = frame["params"]["root"].as_str().unwrap();
            let (output, requests) = run(
                root,
                Some(json!({"id":"register-cli","ok":true,"result":frame["result"]})),
            );
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stdout)
            );
            let doc: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(doc["result"], frame["result"]);
            assert_eq!(requests.len(), 2);
            assert_eq!(requests[1]["method"], "runtime.tool.register");
            assert_eq!(requests[1]["params"], frame["params"]);
        }
        let (output, requests) = run("/fixture/DevEco.app/Contents", None);
        assert_eq!(output.status.code(), Some(75));
        assert_eq!(requests.len(), 2);
        let doc: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(doc["error"]["code"], "outcomeUnknown");
        assert!(doc.get("result").is_none());
    }
    #[test]
    fn hdc_receipts_and_lost_or_inconsistent_responses_never_replay() {
        if !hdc_supported() {
            return;
        }
        let frames: Vec<_> = recordings()
            .into_iter()
            .filter(|v| v["ok"] == true && v["params"]["kind"] == "hdc")
            .collect();
        assert!(
            !frames.is_empty(),
            "candidate must contain real HDC producer responses"
        );
        for frame in frames {
            let file = frame["params"]["file"].as_str().unwrap();
            let receipt = json!({"id":"register-cli","ok":true,"result":frame["result"]});
            let (output, requests) = run_kind("hdc", file, Some(receipt.clone()));
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stdout)
            );
            assert_eq!(requests.len(), 2);
            assert_eq!(requests[1]["params"], frame["params"]);
            let mut bad = receipt.clone();
            bad["result"]["contentDigest"] = json!("0".repeat(64));
            let mut wrong_id = receipt.clone();
            wrong_id["id"] = json!("foreign");
            for response in [
                None,
                Some(bad),
                Some(wrong_id),
                Some(json!({"invalid":true})),
            ] {
                let (output, requests) = run_kind("hdc", file, response);
                assert_eq!(requests.len(), 2);
                assert_eq!(output.status.code(), Some(75));
                let doc: Value = serde_json::from_slice(&output.stdout).unwrap();
                assert_eq!(doc["error"]["code"], "outcomeUnknown");
                assert!(doc.get("result").is_none());
            }
        }
    }
}

fn hdc_supported() -> bool {
    supported()
        && arkdeck_contract::validate_method_value(
            "runtime.tool.register",
            "request",
            &json!({"kind":"hdc","file":"/hdc"}),
        )
        .is_ok()
}
#[test]
fn hdc_request_rejects_wrong_kind_path_and_caller_owned_fields() {
    for file in ["/tmp/hdc", "/tmp/a b/hdc", "//tmp//hdc"] {
        let invocation = parse(&args(&[
            "runtime", "tool", "register", "--kind", "hdc", "--file", file,
        ]))
        .unwrap();
        assert_eq!(
            invocation.params,
            Some(
                json!({"kind":"hdc","file":file})
                    .as_object()
                    .unwrap()
                    .clone()
            )
        );
        let result = validate_bootstrap_request(&invocation);
        if hdc_supported() {
            result.unwrap();
        } else {
            assert_eq!(result.unwrap_err().code, "controlMethodUnavailable");
        }
    }
    for file in [
        "relative",
        "~/hdc",
        "file:///tmp/hdc",
        "/tmp/../hdc",
        "/tmp/./hdc",
        "/tmp/\0hdc",
    ] {
        assert_eq!(
            parse(&args(&[
                "runtime", "tool", "register", "--kind", "hdc", "--file", file
            ]))
            .unwrap_err()
            .code,
            "invalidInput"
        );
    }
    for extra in [
        vec![],
        vec!["--root", "/tmp/root"],
        vec!["--file", "/tmp/a", "--root", "/tmp/root"],
        vec!["--file", "/tmp/a", "--file", "/tmp/b"],
    ] {
        let mut argv = args(&["runtime", "tool", "register", "--kind", "hdc"]);
        argv.extend(args(&extra));
        assert!(parse(&argv).is_err());
    }
}
