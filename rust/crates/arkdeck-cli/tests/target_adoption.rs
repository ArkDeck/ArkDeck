//! `target adopt` and `target availability` as Swift's CLI parses and
//! consumes them: the argv fixtures Swift's CLI publishes, and every answer
//! Swift's daemon gave in the Target adoption oracle
//! (`rust/tests/fixtures/target-adoption`), served to the actual CLI by a fake
//! Runtime that checks each request carries the oracle's parameters.
use arkdeck_cli::parse;
use serde_json::Value;

const ADOPT_ARGV: &str = include_str!("../../../tests/fixtures/current-cli-argv/target.adopt.json");
const AVAILABILITY_ARGV: &str =
    include_str!("../../../tests/fixtures/current-cli-argv/target.availability.json");

fn args(argv: &[&str]) -> Vec<String> {
    argv.iter().map(|arg| (*arg).to_owned()).collect()
}

#[test]
fn published_argv_fixtures_replay() {
    for corpus in [ADOPT_ARGV, AVAILABILITY_ARGV] {
        let doc: Value = serde_json::from_str(corpus).unwrap();
        for case in doc["cases"].as_array().unwrap() {
            let argv: Vec<String> = case["argv"]
                .as_array()
                .unwrap()
                .iter()
                .map(|arg| arg.as_str().unwrap().to_owned())
                .collect();
            let result = parse(&argv);
            if case["name"] == "macosCompatibilityOption" && !cfg!(target_os = "macos") {
                assert_eq!(result.unwrap_err().code, "unsupportedOnPlatform");
            } else if case["expected"]["outcome"] == "failure" {
                assert_eq!(result.unwrap_err().code, case["expected"]["code"], "{case}");
            } else {
                let result = result.unwrap();
                assert_eq!(result.command, doc["command"]);
                assert_eq!(result.help, case["expected"]["outcome"] == "leafHelp");
            }
        }
    }
}

#[test]
fn an_adoption_names_one_exact_observation_by_the_positive_integer_grammar() {
    let parsed = parse(&args(&[
        "target",
        "adopt",
        "--candidate",
        "serial",
        "--observation",
        "obs-a",
        "--observation-generation",
        "4",
    ]))
    .unwrap();
    assert_eq!(parsed.method, "target.adopt");
    assert_eq!(
        Value::Object(parsed.params.unwrap()),
        serde_json::json!({"candidate": "serial", "observationId": "obs-a", "observationGeneration": "4"})
    );
    for generation in ["01", "0", "-1", "9223372036854775808", "four"] {
        let refused = parse(&args(&[
            "target",
            "adopt",
            "--candidate",
            "serial",
            "--observation",
            "obs-a",
            "--observation-generation",
            generation,
        ]))
        .unwrap_err();
        assert_eq!(refused.code, "invalidOption", "{generation}");
    }
    let parsed = parse(&args(&["target", "availability", "--target", "TGT-a"])).unwrap();
    assert_eq!(parsed.method, "target.availability");
    assert_eq!(
        Value::Object(parsed.params.unwrap()),
        serde_json::json!({"targetId": "TGT-a"})
    );
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

    const ORACLE: &str = include_str!("../../../tests/fixtures/target-adoption/cases.json");

    /// What Swift's CLI makes of each recorded answer: the error code and
    /// exit status, or `ok`. The three exchanges whose parameters no argv
    /// can spell (none, or a leading zero) are refused before any connection.
    const EXPECTED: [(&str, &str, i32); 14] = [
        ("adopt.invalid", "invalidOption", 64),
        ("adopt.leadingZero", "invalidOption", 64),
        ("adopt.unknown", "resourceConflict", 65),
        ("adopt", "ok", 0),
        ("adopt.again", "ok", 0),
        ("availability", "ok", 0),
        ("availability.missing", "invalidOption", 64),
        ("availability.unknown", "resourceNotFound", 65),
        ("adopt.readopt", "ok", 0),
        ("adopt.stale", "resourceConflict", 65),
        ("adopt.unauthorized", "targetTrustPending", 75),
        ("adopt.unrelated", "admissionDenied", 77),
        ("adopt.drift", "factsDrifted", 77),
        ("adopt.tooMany", "operationUnavailable", 69),
    ];

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
            "/private/tmp/target-adopt-cli-{:032x}",
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
                // The CLI may already have read the answer and closed its end;
                // only a failure other than that is the fake's.
                if let Err(error) = reader.get_mut().shutdown(Shutdown::Write) {
                    assert_eq!(error.kind(), std::io::ErrorKind::NotConnected, "{error}");
                }
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

    /// The argv that names `params`, if an argv can.
    fn argv(method: &str, params: &Value) -> Option<Vec<String>> {
        let text = |key: &str| params[key].as_str().map(str::to_owned);
        match method {
            "target.adopt" => Some(vec![
                "target".into(),
                "adopt".into(),
                "--candidate".into(),
                text("candidate")?,
                "--observation".into(),
                text("observationId")?,
                "--observation-generation".into(),
                text("observationGeneration")?,
            ]),
            _ => Some(vec![
                "target".into(),
                "availability".into(),
                "--target".into(),
                text("targetId")?,
            ]),
        }
    }

    #[test]
    fn the_cli_consumes_every_answer_the_swift_oracle_recorded() {
        let oracle: Value = serde_json::from_str(ORACLE).unwrap();
        let mut consumed = 0;
        for exchange in oracle["exchanges"].as_array().unwrap() {
            let (name, method) = (
                exchange["name"].as_str().unwrap(),
                exchange["method"].as_str().unwrap(),
            );
            if !["target.adopt", "target.availability"].contains(&method) {
                continue;
            }
            let (_, code, exit) = EXPECTED
                .iter()
                .find(|(expected, ..)| *expected == name)
                .unwrap_or_else(|| panic!("{name} has no expectation"));
            let answer = &exchange["answer"];
            let (output, envelope) = match argv(method, &exchange["params"]) {
                Some(argv) if *exit != 64 => run(
                    &argv,
                    Some((
                        method.into(),
                        exchange["params"].clone(),
                        Reply::Answer(answer.clone()),
                    )),
                ),
                // Spelled with the unspellable parameter left out, or as the
                // oracle sent it: refused locally either way.
                spelled => run(
                    &spelled.unwrap_or_else(|| {
                        method
                            .split('.')
                            .map(str::to_owned)
                            .collect::<Vec<String>>()
                    }),
                    None,
                ),
            };
            assert_eq!(output.status.code(), Some(*exit), "{name}: {envelope}");
            if *code == "ok" {
                assert_eq!(envelope["ok"], true, "{name}");
                assert_eq!(envelope["command"], method, "{name}");
                assert_eq!(envelope["result"], answer["result"], "{name}");
            } else if *exit != 64 {
                assert_eq!(envelope["error"]["code"], *code, "{name}: {envelope}");
            }
            consumed += 1;
        }
        assert_eq!(consumed, EXPECTED.len());
    }

    #[test]
    fn an_adoption_without_its_exact_receipt_or_answer_is_an_unknown_outcome() {
        let oracle: Value = serde_json::from_str(ORACLE).unwrap();
        let adopted = oracle["exchanges"]
            .as_array()
            .unwrap()
            .iter()
            .find(|exchange| exchange["name"] == "adopt")
            .unwrap();
        let params = adopted["params"].clone();
        let argv = argv("target.adopt", &params).unwrap();
        for (key, replacement) in [
            ("observationId", json!("obs-other")),
            ("snapshotGeneration", json!("2")),
            ("outcome", json!("reused")),
        ] {
            let mut answer = adopted["answer"].clone();
            answer["result"][key] = replacement;
            let (output, envelope) = run(
                &argv,
                Some(("target.adopt".into(), params.clone(), Reply::Answer(answer))),
            );
            assert_eq!(output.status.code(), Some(75), "{key}: {envelope}");
            assert_eq!(envelope["error"]["code"], "outcomeUnknown", "{key}");
            assert_eq!(envelope["error"]["controlRequestRetryable"], false, "{key}");
        }
        let (output, envelope) = run(&argv, Some(("target.adopt".into(), params, Reply::Close)));
        assert_eq!(output.status.code(), Some(75), "{envelope}");
        assert_eq!(envelope["error"]["code"], "outcomeUnknown");
        // A read whose answer is lost is only an unavailable Runtime.
        let params = json!({"targetId": "TGT-3ba3f5f43b92"});
        let (output, envelope) = run(
            &super::args(&["target", "availability", "--target", "TGT-3ba3f5f43b92"]),
            Some(("target.availability".into(), params, Reply::Close)),
        );
        assert_eq!(output.status.code(), Some(69), "{envelope}");
        assert_eq!(envelope["error"]["code"], "runtimeUnavailable");
    }
}
