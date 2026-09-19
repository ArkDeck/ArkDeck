use arkdeck_cli::*;
use serde_json::{Value, json};
fn args(v: &[&str]) -> Vec<String> {
    v.iter().map(|v| (*v).into()).collect()
}

#[test]
fn resume_options_are_closed_and_do_not_supply_a_new_intent() {
    let parsed = parse(&args(&[
        "agent",
        "resume",
        "--resume-token",
        "resume-1",
        "--selection",
        "candidate-1",
        "--timeout",
        "2s",
    ]))
    .unwrap();
    assert_eq!(parsed.timeout_ms, Some(2000));
    assert_eq!(
        resume_params(&parsed).unwrap(),
        serde_json::from_value::<serde_json::Map<String, Value>>(
            json!({"resumeReference":"resume-1","selection":"candidate-1"})
        )
        .unwrap()
    );
    for options in [
        vec![],
        vec![
            "--resume-reference",
            "resume-1",
            "--resume-token",
            "resume-2",
        ],
        vec![
            "--resume-reference",
            "resume-1",
            "--selection",
            "candidate-1",
            "--selection-file",
            "x",
        ],
        vec!["--resume-reference", "resume-1", "--maximum-wait", "1h"],
        vec!["--resume-reference", "resume-1", "--target", "target-1"],
        vec!["--resume-reference", "resume-1", "--capability", "cap-1"],
    ] {
        let mut argv = vec!["agent", "resume"];
        argv.extend(options);
        assert!(parse(&args(&argv)).is_err());
    }
    assert!(
        parse(&args(&[
            "human-action",
            "resume",
            "--resume-reference",
            "resume-1"
        ]))
        .is_err()
    );
    let path = std::env::temp_dir().join(format!("resume-selection-{}.json", std::process::id()));
    let argv = args(&[
        "agent",
        "resume",
        "--resume-reference",
        "resume-1",
        "--selection-file",
        path.to_str().unwrap(),
    ]);
    std::fs::write(&path, b"\"candidate-1\"").unwrap();
    assert_eq!(
        resume_params(&parse(&argv).unwrap()).unwrap()["selection"],
        "candidate-1"
    );
    for bytes in [
        b"{}".to_vec(),
        vec![b' '; 65_537],
        b"{\"a\":1,\"a\":2}".to_vec(),
    ] {
        std::fs::write(&path, bytes).unwrap();
        assert!(resume_params(&parse(&argv).unwrap()).is_err());
    }
    std::fs::remove_file(path).unwrap();
}

#[cfg(target_os = "macos")]
mod runtime {
    use super::*;
    use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
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
            "/private/tmp/agent-resume-cli-{:032x}",
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
    fn resume_sends_once_preserves_receipts_and_never_replays_lost_responses() {
        let oracle: Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/agent-human-action/cases.json"
        ))
        .unwrap();
        let answer = oracle["exchanges"]
            .as_array()
            .unwrap()
            .iter()
            .find(|x| x["name"] == "connect.again")
            .unwrap()["answer"]
            .clone();
        for method in ["agent.resume", "human-action.resume"] {
            let mut argv = args(&[
                if method == "agent.resume" {
                    "agent"
                } else {
                    "human-action"
                },
                "resume",
                "--resume-reference",
                "resume-1",
            ]);
            let mut params = json!({"resumeReference":"resume-1"});
            if method == "human-action.resume" {
                argv.extend(args(&["--human-action", "har-1"]));
                params["humanAction"] = json!("har-1");
            }
            let (output, envelope) = run(
                &argv,
                Some((method.into(), params.clone(), Reply::Answer(answer.clone()))),
            );
            assert_eq!(output.status.code(), Some(0), "{envelope}");
            assert_eq!(envelope["result"]["jobId"], answer["result"]["jobId"]);
            let (output, envelope) = run(&argv, Some((method.into(), params, Reply::Close)));
            assert_eq!(output.status.code(), Some(75), "{envelope}");
            assert_eq!(envelope["error"]["code"], "outcomeUnknown");
            assert_eq!(envelope["error"]["controlRequestRetryable"], false);
        }
    }
}
