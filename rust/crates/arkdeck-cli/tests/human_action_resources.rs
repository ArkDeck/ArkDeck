//! Human-action reads preserve Swift argv, wire projections, and refusal codes.
use arkdeck_cli::{CliError, parse};
use arkdeck_client::ClientError;
use arkdeck_contract::WireError;
use serde_json::{Value, json};

fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

#[test]
fn swift_argv_fixtures() {
    for text in [
        include_str!("../../../tests/fixtures/current-cli-argv/human-action.list.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/human-action.show.json"),
    ] {
        let fixture: Value = serde_json::from_str(text).unwrap();
        for row in fixture["cases"].as_array().unwrap() {
            let argv: Vec<_> = row["argv"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap().to_owned())
                .collect();
            let result = parse(&argv);
            if row["name"] == "macosCompatibilityOption" && !cfg!(target_os = "macos") {
                assert_eq!(result.unwrap_err().code, "unsupportedOnPlatform");
            } else if row["expected"]["outcome"] == "failure" {
                let error = result.unwrap_err();
                assert_eq!(error.code, row["expected"]["code"], "{row}");
                assert_eq!(json!(error.exit_code()), row["expected"]["exitCode"]);
            } else {
                let invocation = result.unwrap();
                assert_eq!(invocation.command, fixture["command"]);
                assert_eq!(invocation.method, fixture["command"]);
                assert_eq!(invocation.help, row["expected"]["outcome"] == "leafHelp");
            }
        }
    }
}

#[test]
fn typed_filters_and_local_deadline() {
    let invocation = parse(&args(&[
        "human-action",
        "list",
        "--owner-kind",
        "agentExecution",
        "--owner",
        "execution-1",
        "--page-size",
        "12",
        "--cursor",
        "opaque-cursor",
        "--timeout",
        "2m",
    ]))
    .unwrap();
    assert_eq!(invocation.timeout_ms, Some(120_000));
    assert_eq!(
        json!(invocation.params),
        json!({"ownerKind":"agentExecution","owner":"execution-1","pageSize":12,"cursor":"opaque-cursor"})
    );
    assert_eq!(
        json!(parse(&args(&["human-action", "list"])).unwrap().params),
        json!({})
    );
    let invocation = parse(&args(&[
        "human-action",
        "show",
        "--human-action",
        "har-1",
        "--timeout",
        "10ms",
    ]))
    .unwrap();
    assert_eq!(invocation.timeout_ms, Some(10));
    assert_eq!(json!(invocation.params), json!({"humanAction":"har-1"}));
}

#[test]
fn rejects_unbounded_or_misrouted_arguments() {
    for (extra, code) in [
        (vec!["--owner-kind", "agentExecution"], "invalidInput"),
        (vec!["--owner", "owner-1"], "invalidInput"),
        (
            vec!["--owner-kind", "job", "--owner", "job-1"],
            "invalidOption",
        ),
        (vec!["--page-size", "0"], "invalidOption"),
        (vec!["--page-size", "01"], "invalidOption"),
        (vec!["--page-size", "1001"], "invalidOption"),
        (vec!["--timeout", "25h"], "invalidOption"),
        (vec!["--timeout", "0s"], "invalidOption"),
        (vec!["--state", "waiting"], "invalidOption"),
        (vec!["--human-action", "har-1"], "invalidOption"),
    ] {
        let mut argv = args(&["human-action", "list"]);
        argv.extend(args(&extra));
        assert_eq!(parse(&argv).unwrap_err().code, code, "{argv:?}");
    }
    for id in ["", "../har", "har:1", "-har", "a\nb"] {
        assert_eq!(
            parse(&args(&["human-action", "show", "--human-action", id]))
                .unwrap_err()
                .code,
            "invalidInput"
        );
    }
    assert_eq!(
        parse(&args(&["human-action", "resume"])).unwrap_err().code,
        "invalidCommand"
    );
}

#[test]
fn read_refusals_require_proof_and_transport_is_retryable_read() {
    for method in ["human-action.list", "human-action.show"] {
        for code in [
            "invalidInput",
            "invalidCursor",
            "resourceNotFound",
            "operationUnavailable",
        ] {
            for proven in [true, false] {
                let error = CliError::from_client(
                    ClientError::Remote(WireError {
                        code: code.into(),
                        message: "refused".into(),
                        details: proven.then(|| {
                            json!({"phase":"preAdmission","newDispatchCount":0})
                                .as_object()
                                .unwrap()
                                .clone()
                        }),
                    }),
                    method,
                );
                assert_eq!(error.code, if proven { code } else { "internalError" });
                assert_eq!(error.details["method"], method);
            }
        }
        let error = CliError::from_client(
            ClientError::Transport(std::io::Error::from(std::io::ErrorKind::TimedOut)),
            method,
        );
        assert_eq!((error.code, error.exit_code()), ("clientTimeout", 75));
    }
}

#[cfg(target_os = "macos")]
mod runtime {
    use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
    use serde_json::{Value, json};
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::Shutdown;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use std::process::{Command, Output};

    /// What the fake Runtime does once it has read the request.
    enum Reply {
        Answer(Value),
        Close,
    }

    /// The actual CLI run with `argv` against a fake Runtime. With an
    /// exchange, the Runtime answers health, reads exactly one request of
    /// that method and parameters and replies; without one, the CLI must not
    /// connect at all. It never accepts a replay or a second connection.
    fn run(argv: &[String], exchange: Option<(String, Value, Reply)>) -> (Output, Value) {
        let root = PathBuf::from(format!(
            "/private/tmp/har-cli-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&root)
            .unwrap();
        let path = root.join("a.sock");
        let listener = UnixListener::bind(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let server = exchange.map(|(method, params, reply)| {
            let acceptor = listener.try_clone().unwrap();
            std::thread::spawn(move || {
                let (stream, _) = acceptor.accept().unwrap();
                stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                    .unwrap();
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let health: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(health["method"], "health");
                let health = json!({"id":"health","ok":true,"result":{"status":"ok","protocolVersion":PROTOCOL_VERSION,
                    "contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,"providers":[],"publishedMethods":METHODS}});
                writeln!(reader.get_mut(), "{health}").unwrap();
                line.clear();
                reader.read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(request["method"], method);
                assert_eq!(request["params"], params, "the oracle's parameters");
                if let Reply::Answer(mut answer) = reply {
                    answer["id"] = request["id"].clone();
                    writeln!(reader.get_mut(), "{answer}").unwrap();
                }
                reader.get_mut().shutdown(Shutdown::Write).unwrap();
                let mut extra = Vec::new();
                reader.read_to_end(&mut extra).unwrap();
                assert!(extra.is_empty(), "the CLI never replays a request");
            })
        });
        let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(argv)
            .args(["--output", "json", "--socket"])
            .arg(&path)
            .output()
            .unwrap();
        if let Some(server) = server {
            server.join().unwrap();
        }
        listener.set_nonblocking(true).unwrap();
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
            "no connection beyond the exchange"
        );
        drop(listener);
        std::fs::remove_dir_all(root).unwrap();
        let envelope = serde_json::from_slice(&output.stdout).unwrap_or(Value::Null);
        (output, envelope)
    }

    #[test]
    fn recorded_swift_success_projections_pass_through_the_binary() {
        for corpus in [
            include_str!(
                "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/human-action.list.jsonl"
            ),
            include_str!(
                "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/human-action.show.jsonl"
            ),
        ] {
            for line in corpus.lines() {
                let frame: Value = serde_json::from_str(line).unwrap();
                if frame["ok"] != true {
                    continue;
                }
                let method = frame["method"].as_str().unwrap();
                let mut argv: Vec<String> = method.split('.').map(str::to_owned).collect();
                for (key, value) in frame["params"].as_object().unwrap() {
                    let flag = match key.as_str() {
                        "humanAction" => "--human-action",
                        "ownerKind" => "--owner-kind",
                        "owner" => "--owner",
                        "pageSize" => "--page-size",
                        "cursor" => "--cursor",
                        _ => panic!("unexpected request field"),
                    };
                    argv.push(flag.into());
                    argv.push(
                        value
                            .as_str()
                            .map(str::to_owned)
                            .unwrap_or_else(|| value.to_string()),
                    );
                }
                let answer = json!({"ok":true,"result":frame["result"]});
                let (output, envelope) = run(
                    &argv,
                    Some((
                        method.into(),
                        frame["params"].clone(),
                        Reply::Answer(answer),
                    )),
                );
                assert_eq!(output.status.code(), Some(0), "{envelope}");
                assert_eq!(envelope["command"], method);
                assert_eq!(envelope["result"], frame["result"]);
            }
        }
    }

    #[test]
    fn lost_reply_is_not_replayed_and_invalid_identity_never_connects() {
        let argv = super::args(&["human-action", "show", "--human-action", "har-1"]);
        let (output, envelope) = run(
            &argv,
            Some((
                "human-action.show".into(),
                json!({"humanAction":"har-1"}),
                Reply::Close,
            )),
        );
        assert_ne!(output.status.code(), Some(0));
        assert_ne!(envelope["error"]["code"], "outcomeUnknown");
        let (output, envelope) = run(
            &super::args(&["human-action", "show", "--human-action", "../escape"]),
            None,
        );
        assert_eq!(output.status.code(), Some(65));
        assert_eq!(envelope["error"]["code"], "invalidInput");
    }
}
