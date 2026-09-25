//! `arkdeck recovery cleanup list` with its deprecated `cleanup-debt list`,
//! and `arkdeck trace export`, against a fake Runtime answering what Swift's
//! daemon recorded (`Fixtures/ControlFrames/{cleanupDebt.list,
//! artifact.inspect}.jsonl`).
//!
//! - Both cleanup spellings send one `cleanupDebt.list` and print its answer.
//!   The deprecated one says so in `meta.lifecycle`.
//! - `device list` and `device show`, legacy, both send one parameterless
//!   `target.list` (Swift `runDevice`) and say what replaces them.
//! - Both `recovery cleanup continue` spellings send one `cleanupDebt.continue`
//!   with the Job and its one recorded residue, a remote path or a bundle,
//!   and print its answer. A reply that is lost once the request went out is
//!   an unknown outcome, never replayed.
//! - `trace export` is `artifact export` of the one Trace a diagnostics
//!   capture publishes. The inspected Artifact must be that Trace before
//!   anything is exported.
// The fake Runtime these leaves are driven against is a Unix socket.
#[cfg(target_os = "macos")]
mod support;

#[cfg(target_os = "macos")]
mod runtime {
    use super::support;
    use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
    use serde_json::{Value, json};

    fn health() -> (String, Value, Value) {
        (
            "health".to_owned(),
            Value::Null,
            json!({"ok":true,"result":{"status":"ok","protocolVersion":PROTOCOL_VERSION,
                "contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,
                "providers":["hdc"],"publishedMethods":METHODS}}),
        )
    }

    fn frames(method: &str) -> Vec<Value> {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
            "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
        ));
        std::fs::read_to_string(path)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    #[test]
    fn both_cleanup_spellings_list_the_debt_as_the_runtime_answers() {
        // A recorded answer that names one debt.
        let answer = frames("cleanupDebt.list")
            .into_iter()
            .find(|frame| {
                frame["ok"] == true
                    && frame["result"]
                        .as_array()
                        .is_some_and(|debts| !debts.is_empty())
            })
            .expect("Swift recorded a cleanup debt");
        let answer = json!({"ok": true, "result": answer["result"]});
        for (path, command, lifecycle) in [
            (
                ["recovery", "cleanup", "list"].as_slice(),
                "recovery.cleanup.list",
                None,
            ),
            (
                ["cleanup-debt", "list"].as_slice(),
                "cleanup-debt.list",
                Some(json!({"status": "deprecated",
                    "replacementArgvPattern": "arkdeck recovery cleanup list",
                    "removalVersion": null})),
            ),
        ] {
            let (output, envelope) = support::run_session(
                path,
                vec![
                    health(),
                    ("cleanupDebt.list".to_owned(), Value::Null, answer.clone()),
                ],
            );
            assert_eq!(output.status.code(), Some(0), "{envelope}");
            assert_eq!(envelope["command"], command);
            assert_eq!(envelope["result"], answer["result"]);
            assert_eq!(
                envelope["meta"].get("lifecycle").cloned(),
                lifecycle,
                "{command}"
            );
        }
    }

    #[test]
    fn both_legacy_device_spellings_read_the_target_list() {
        let answer = frames("target.list")
            .into_iter()
            .find(|frame| {
                frame["ok"] == true
                    && frame["result"]
                        .as_array()
                        .is_some_and(|targets| !targets.is_empty())
            })
            .expect("Swift recorded a target");
        let answer = json!({"ok": true, "result": answer["result"]});
        for (verb, replacement) in [
            ("list", "arkdeck target list"),
            ("show", "arkdeck target show --target <id>"),
        ] {
            let command = format!("device.{verb}");
            let (output, envelope) = support::run_session(
                &["device", verb],
                vec![
                    health(),
                    ("target.list".to_owned(), Value::Null, answer.clone()),
                ],
            );
            assert_eq!(output.status.code(), Some(0), "{envelope}");
            assert_eq!(envelope["command"], command.as_str());
            assert_eq!(envelope["result"], answer["result"]);
            assert_eq!(
                envelope["meta"]["lifecycle"],
                json!({"status": "legacy", "replacementArgvPattern": replacement,
                    "removalVersion": null})
            );
            assert!(output.stderr.is_empty(), "{command}");
            // In the human rendering the warning is on stderr, before the
            // answer on stdout.
            let (output, _) = support::run_session(
                &["device", verb, "--output", "human"],
                vec![
                    health(),
                    ("target.list".to_owned(), Value::Null, answer.clone()),
                ],
            );
            assert_eq!(output.status.code(), Some(0));
            assert_eq!(
                String::from_utf8(output.stderr).unwrap(),
                format!("warning: `device {verb}` is legacy; use `{replacement}`\n")
            );
            assert_eq!(
                serde_json::from_slice::<Value>(&output.stdout).unwrap(),
                answer["result"]
            );
        }
    }

    /// Swift's recorded `cleanupDebt.continue` exchanges.
    fn continuations() -> Vec<Value> {
        frames("cleanupDebt.continue")
    }

    #[test]
    fn both_cleanup_spellings_continue_the_recorded_residue() {
        let answered: Vec<Value> = continuations()
            .into_iter()
            .filter(|frame| frame["ok"] == true)
            .collect();
        assert_eq!(answered.len(), 2);
        for (frame, (path, command, lifecycle)) in answered.iter().zip([
            (
                ["recovery", "cleanup", "continue"].as_slice(),
                "recovery.cleanup.continue",
                None,
            ),
            (
                ["cleanup-debt", "continue"].as_slice(),
                "cleanup-debt.continue",
                Some(json!({"status": "deprecated",
                    "replacementArgvPattern": "arkdeck recovery cleanup continue --job <id> ...",
                    "removalVersion": null})),
            ),
        ]) {
            let params = &frame["params"];
            let mut argv: Vec<&str> = path.to_vec();
            argv.extend(["--job", params["jobId"].as_str().unwrap()]);
            match params.get("remotePath") {
                Some(remote) => argv.extend(["--remote-path", remote.as_str().unwrap()]),
                None => argv.extend(["--bundle", params["bundleName"].as_str().unwrap()]),
            }
            let answer = json!({"ok": true, "result": frame["result"]});
            let (output, envelope) = support::run_session(
                &argv,
                vec![
                    health(),
                    ("cleanupDebt.continue".to_owned(), params.clone(), answer),
                ],
            );
            assert_eq!(output.status.code(), Some(0), "{envelope}");
            assert_eq!(envelope["command"], command);
            assert_eq!(envelope["result"], frame["result"]);
            assert_eq!(
                envelope["meta"].get("lifecycle").cloned(),
                lifecycle,
                "{command}"
            );
        }
    }

    #[test]
    fn a_refused_continuation_is_the_runtimes_refusal() {
        let refused = continuations()
            .into_iter()
            .find(|frame| frame["ok"] == false)
            .unwrap();
        let (output, envelope) = support::run_session(
            &[
                "recovery", "cleanup", "continue", "--job", "job-1", "--bundle", "b",
            ],
            vec![
                health(),
                (
                    "cleanupDebt.continue".to_owned(),
                    json!({"jobId": "job-1", "bundleName": "b"}),
                    json!({"ok": false, "error": refused["error"]}),
                ),
            ],
        );
        let expected = arkdeck_cli::CliError::from_client(
            arkdeck_client::ClientError::Remote(arkdeck_contract::WireError {
                code: refused["error"]["code"].as_str().unwrap().into(),
                message: refused["error"]["message"].as_str().unwrap().into(),
                details: None,
            }),
            "cleanupDebt.continue",
        );
        assert_eq!(envelope["error"]["code"], expected.code);
        assert_eq!(envelope["error"]["message"], expected.message);
        assert_eq!(output.status.code(), Some(i32::from(expected.exit_code())));
        assert_eq!(
            envelope["error"]["details"],
            serde_json::Value::Object(expected.details)
        );
    }

    /// The request went out and no reply came back: the cleanup may have run,
    /// so the answer is an unknown outcome and the request is not sent again.
    #[test]
    fn a_lost_reply_to_a_continuation_is_an_unknown_outcome() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        let root = std::fs::canonicalize("/tmp").unwrap().join(format!(
            "arkdeck-cli-continue-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&root)
            .unwrap();
        let socket = root.join("a.sock");
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let health_request: Value = serde_json::from_str(&line).unwrap();
            let mut answer = health().2;
            answer["id"] = health_request["id"].clone();
            writeln!(reader.get_mut(), "{answer}").unwrap();
            line.clear();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            // Closed without a reply.
            drop(reader);
            (request, listener)
        });
        let output = std::process::Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args([
                "cleanup-debt",
                "continue",
                "--job",
                "job-1",
                "--remote-path",
                "/data/x",
                "--output",
                "json",
                "--socket",
            ])
            .arg(&socket)
            .output()
            .unwrap();
        let (request, listener) = server.join().unwrap();
        // The CLI has exited, so any connection it made is already queued.
        listener.set_nonblocking(true).unwrap();
        let no_second = matches!(listener.accept(),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock);
        std::fs::remove_dir_all(&root).unwrap();
        assert_eq!(request["method"], "cleanupDebt.continue");
        assert_eq!(
            request["params"],
            json!({"jobId": "job-1", "remotePath": "/data/x"})
        );
        assert!(no_second, "the request was not sent again");
        let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(envelope["error"]["code"], "outcomeUnknown", "{envelope}");
        assert_eq!(
            envelope["error"]["details"]["method"],
            "cleanupDebt.continue"
        );
        assert_eq!(output.status.code(), Some(75));
    }

    /// A published Artifact Swift recorded, as the Trace a diagnostics
    /// capture publishes.
    fn trace() -> Value {
        let mut metadata = frames("artifact.inspect")
            .into_iter()
            .find(|frame| {
                frame["ok"] == true
                    && frame["result"]["status"] == "published"
                    && frame["result"]["owner"]["kind"] == "job"
            })
            .expect("Swift recorded a published Job Artifact")["result"]
            .clone();
        metadata["sourceOperation"] = json!("capture.diagnostics@1");
        metadata["name"] = json!("trace.htrace");
        metadata["mediaType"] = json!("application/octet-stream");
        metadata["privacy"] = json!("sensitive");
        metadata
    }

    fn argv(metadata: &Value) -> Vec<String> {
        [
            "trace",
            "export",
            "--job",
            metadata["owner"]["id"].as_str().unwrap(),
            "--artifact",
            metadata["artifactId"].as_str().unwrap(),
            "--destination",
            "/tmp/arkdeck-trace-export-out",
            "--allow-sensitive",
        ]
        .iter()
        .map(|argument| (*argument).to_owned())
        .collect()
    }

    fn inspect(metadata: &Value) -> (String, Value, Value) {
        (
            "artifact.inspect".to_owned(),
            json!({"owner": metadata["owner"], "artifactId": metadata["artifactId"]}),
            json!({"ok": true, "result": metadata}),
        )
    }

    #[test]
    fn trace_export_exports_the_inspected_trace() {
        let metadata = trace();
        let receipt = json!({"schemaVersion": "arkdeck.artifact-export/1",
            "owner": metadata["owner"], "artifactId": metadata["artifactId"],
            "artifactDigest": metadata["artifactDigest"], "byteCount": metadata["byteCount"],
            "privacy": "sensitive", "overwritten": false,
            "exportedPath": format!("/private/tmp/arkdeck-trace-export-out/{}-trace.htrace",
                metadata["artifactId"].as_str().unwrap())});
        let argv = argv(&metadata);
        let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
        let (output, envelope) = support::run_session(
            &argv,
            vec![
                health(),
                inspect(&metadata),
                (
                    "artifact.export".to_owned(),
                    json!({"owner": metadata["owner"], "artifactId": metadata["artifactId"],
                        "destinationDirectory": "/private/tmp/arkdeck-trace-export-out",
                        "allowSensitive": true, "overwrite": false}),
                    json!({"ok": true, "result": receipt}),
                ),
            ],
        );
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        assert_eq!(envelope["command"], "trace.export");
        assert_eq!(envelope["result"], receipt);
    }

    #[test]
    fn trace_export_refuses_any_other_artifact_before_exporting_it() {
        let mut elsewhere = trace();
        elsewhere["sourceOperation"] = json!("observe.device@1");
        let mut hilog = trace();
        hilog["name"] = json!("hilog.txt");
        let mut standard = trace();
        standard["privacy"] = json!("standard");
        for (metadata, message) in [
            (
                elsewhere,
                "selected Artifact does not belong to capture.diagnostics@1",
            ),
            (
                hilog,
                "selected Artifact does not match the required typed resource",
            ),
            (
                standard,
                "selected Artifact does not match the required typed resource",
            ),
        ] {
            let argv = argv(&metadata);
            let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
            // The fake answers the inspection only: an export request would
            // be one exchange beyond those named, and fail the test.
            let (output, envelope) =
                support::run_session(&argv, vec![health(), inspect(&metadata)]);
            assert_eq!(output.status.code(), Some(65), "{envelope}");
            assert_eq!(envelope["command"], "trace.export");
            assert_eq!(envelope["error"]["code"], "invalidInput");
            assert_eq!(envelope["error"]["message"], message);
        }
    }
}

/// A continuation names its Job and exactly one recorded residue; anything
/// else is refused before a connection, with the registry's words.
#[test]
fn a_continuation_needs_its_job_and_exactly_one_residue() {
    for (argv, message) in [
        (
            vec!["recovery", "cleanup", "continue", "--job", "j"],
            "`recovery cleanup continue` requires exactly one of --remote-path, --bundle",
        ),
        (
            vec![
                "cleanup-debt",
                "continue",
                "--job",
                "j",
                "--remote-path",
                "/a",
                "--bundle",
                "b",
            ],
            "`cleanup-debt continue` requires exactly one of --remote-path, --bundle",
        ),
        (
            vec!["recovery", "cleanup", "continue", "--bundle", "b"],
            "`recovery cleanup continue` requires --job <job-id>",
        ),
    ] {
        let argv: Vec<String> = argv.into_iter().map(str::to_owned).collect();
        let error = arkdeck_cli::parse(&argv).unwrap_err();
        assert_eq!((error.code, error.exit_code()), ("invalidOption", 64));
        assert_eq!(error.message, message, "{argv:?}");
    }
}
