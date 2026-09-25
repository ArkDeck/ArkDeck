//! `arkdeck recovery flash-invocation start|evaluate` and their legacy
//! spellings `arkdeck debug start|evaluate` against a fake Runtime that
//! answers what Swift's daemon answered in the Flash recovery broker oracle
//! (`rust/tests/fixtures/debug-invocation`): each leaf reads its document
//! whole, sends exactly its one request and emits the Runtime's answer, and
//! the legacy spellings say what replaces them.
// The fake Runtime these leaves are driven against is a Unix socket.
#[cfg(target_os = "macos")]
mod support;

#[cfg(target_os = "macos")]
mod runtime {
    use super::support;
    use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
    use serde_json::{Value, json};
    use std::path::PathBuf;

    fn health() -> (String, Value, Value) {
        (
            "health".to_owned(),
            Value::Null,
            json!({"ok":true,"result":{"status":"ok","protocolVersion":PROTOCOL_VERSION,
                "contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,
                "providers":["hdc"],"publishedMethods":METHODS}}),
        )
    }

    /// One exchange of the oracle, by name.
    fn exchange(name: &str) -> Value {
        let cases: Value = serde_json::from_slice(
            &std::fs::read(
                std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../../tests/fixtures/debug-invocation/cases.json"),
            )
            .unwrap(),
        )
        .unwrap();
        cases["exchanges"]
            .as_array()
            .unwrap()
            .iter()
            .find(|exchange| exchange["name"] == name)
            .unwrap_or_else(|| panic!("the oracle recorded {name}"))
            .clone()
    }

    /// A document the leaf reads, in a private directory of its own.
    struct Document(PathBuf);

    impl Document {
        fn new(text: &str) -> Self {
            let directory = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "arkdeck-cli-broker-{:032x}",
                u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
            ));
            std::fs::create_dir(&directory).unwrap();
            let path = directory.join("document.json");
            std::fs::write(&path, text).unwrap();
            Self(path)
        }

        fn path(&self) -> &str {
            self.0.to_str().unwrap()
        }
    }

    impl Drop for Document {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(self.0.parent().unwrap());
        }
    }

    fn lifecycle(legacy: bool, replacement: &str) -> Option<Value> {
        legacy.then(|| {
            json!({
                "status": "legacy", "replacementArgvPattern": replacement,
                "removalVersion": null,
            })
        })
    }

    #[test]
    fn both_start_spellings_send_the_request_document_as_it_is_written() {
        let started = exchange("start.canonical");
        let seed = started["params"]["requestJson"]
            .as_str()
            .unwrap()
            .to_owned();
        let request = Document::new(&seed);
        for (path, command, legacy) in [
            (
                ["recovery", "flash-invocation", "start"].as_slice(),
                "recovery.flash-invocation.start",
                false,
            ),
            (["debug", "start"].as_slice(), "debug.start", true),
        ] {
            let mut argv = path.to_vec();
            argv.extend(["--request-file", request.path()]);
            let (output, envelope) = support::run_session(
                &argv,
                vec![
                    health(),
                    (
                        "debug.start".to_owned(),
                        json!({"requestJson": seed}),
                        started["answer"].clone(),
                    ),
                ],
            );
            assert_eq!(output.status.code(), Some(0), "{envelope}");
            assert_eq!(envelope["command"], command);
            assert_eq!(envelope["result"], started["answer"]["result"]);
            assert_eq!(
                envelope["meta"].get("lifecycle").cloned(),
                lifecycle(
                    legacy,
                    "arkdeck recovery flash-invocation start --request-file <path>"
                ),
                "{command}"
            );
        }
    }

    #[test]
    fn both_evaluate_spellings_send_the_candidate_and_its_provenance() {
        // An observed evaluation: a shape the published view's schema admits
        // as well as this checkout's.
        let observed = exchange("evaluate.observe");
        let params = observed["params"].clone();
        let action = Document::new(params["actionJson"].as_str().unwrap());
        let identity = observed["answer"]["result"]["invocationID"]
            .as_str()
            .unwrap()
            .to_owned();
        for (path, command, legacy) in [
            (
                ["recovery", "flash-invocation", "evaluate"].as_slice(),
                "recovery.flash-invocation.evaluate",
                false,
            ),
            (["debug", "evaluate"].as_slice(), "debug.evaluate", true),
        ] {
            let mut argv = path.to_vec();
            argv.extend([
                "--invocation",
                &identity,
                "--action-file",
                action.path(),
                "--source-sha256",
                params["sourceSha256"].as_str().unwrap(),
                "--build-sha256",
                params["buildSha256"].as_str().unwrap(),
            ]);
            let (output, envelope) = support::run_session(
                &argv,
                vec![
                    health(),
                    (
                        "debug.evaluate".to_owned(),
                        json!({
                            "invocationId": identity, "actionJson": params["actionJson"],
                            "sourceSha256": params["sourceSha256"],
                            "buildSha256": params["buildSha256"],
                        }),
                        observed["answer"].clone(),
                    ),
                ],
            );
            assert_eq!(output.status.code(), Some(0), "{envelope}");
            assert_eq!(envelope["command"], command);
            assert_eq!(envelope["result"], observed["answer"]["result"]);
            assert_eq!(
                envelope["meta"].get("lifecycle").cloned(),
                lifecycle(
                    legacy,
                    "arkdeck recovery flash-invocation evaluate --invocation <id> ..."
                ),
                "{command}"
            );
        }

        // The broker's refusal is the Runtime's own, with its words. The
        // oracle records an absent `details` as null; the wire omits it.
        let mut refused = exchange("evaluate.afterStop");
        refused["answer"]["error"]
            .as_object_mut()
            .unwrap()
            .remove("details");
        let (output, envelope) = support::run_session(
            &[
                "recovery",
                "flash-invocation",
                "evaluate",
                "--invocation",
                &identity,
                "--action-file",
                action.path(),
                "--source-sha256",
                params["sourceSha256"].as_str().unwrap(),
                "--build-sha256",
                params["buildSha256"].as_str().unwrap(),
            ],
            vec![
                health(),
                (
                    "debug.evaluate".to_owned(),
                    json!({
                        "invocationId": identity, "actionJson": params["actionJson"],
                        "sourceSha256": params["sourceSha256"],
                        "buildSha256": params["buildSha256"],
                    }),
                    refused["answer"].clone(),
                ),
            ],
        );
        assert_ne!(output.status.code(), Some(0));
        assert_eq!(envelope["ok"], false);
        assert_eq!(
            envelope["error"]["message"],
            refused["answer"]["error"]["message"]
        );
    }

    /// The current spelling's registry takes both pinned digests as 64
    /// lowercase hex digits, judged at parse, before the action is read; the
    /// legacy spelling takes them opaque and sends them, and the Runtime's
    /// refusal is Swift's (the oracle's two provenance exchanges).
    #[test]
    fn a_pinned_digest_outside_the_current_grammar_is_refused_at_parse() {
        let invocation = "debug-00000000-0000-4000-8000-000000000000";
        for (name, option) in [
            ("evaluate.provenance.uppercase", "--source-sha256"),
            ("evaluate.provenance.short", "--build-sha256"),
        ] {
            let mut recorded = exchange(name);
            recorded["answer"]["error"]
                .as_object_mut()
                .unwrap()
                .remove("details");
            let params = &recorded["params"];
            let (source, build) = (
                params["sourceSha256"].as_str().unwrap(),
                params["buildSha256"].as_str().unwrap(),
            );
            let output = std::process::Command::new(env!("CARGO_BIN_EXE_arkdeck"))
                .args(["recovery", "flash-invocation", "evaluate"])
                .args(["--invocation", invocation])
                .args([
                    "--action-file",
                    "/nonexistent/arkdeck-cli-broker-action.json",
                ])
                .args(["--source-sha256", source, "--build-sha256", build])
                .args([
                    "--socket",
                    "/nonexistent/arkdeck-cli-broker.sock",
                    "--output",
                    "json",
                ])
                .output()
                .unwrap();
            let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(output.status.code(), Some(64), "{name}: {envelope}");
            assert_eq!(envelope["command"], "recovery.flash-invocation.evaluate");
            assert_eq!(envelope["error"]["code"], "invalidOption");
            assert_eq!(
                envelope["error"]["message"],
                format!(
                    "`recovery flash-invocation evaluate` {option} must be 64 lowercase hex digits"
                )
            );

            let action = Document::new(params["actionJson"].as_str().unwrap());
            let (output, envelope) = support::run_session(
                &[
                    "debug",
                    "evaluate",
                    "--invocation",
                    invocation,
                    "--action-file",
                    action.path(),
                    "--source-sha256",
                    source,
                    "--build-sha256",
                    build,
                ],
                vec![
                    health(),
                    (
                        "debug.evaluate".to_owned(),
                        json!({
                            "invocationId": invocation, "actionJson": params["actionJson"],
                            "sourceSha256": source, "buildSha256": build,
                        }),
                        recorded["answer"].clone(),
                    ),
                ],
            );
            assert_ne!(output.status.code(), Some(0), "{name}");
            assert_eq!(envelope["command"], "debug.evaluate");
            assert_eq!(
                envelope["error"]["message"], recorded["answer"]["error"]["message"],
                "{name}: {envelope}"
            );
        }
    }

    #[test]
    fn a_document_the_leaf_cannot_read_is_refused_before_any_connection() {
        let missing = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join("arkdeck-cli-broker-no-such-document.json");
        let missing = missing.to_str().unwrap();
        for argv in [
            vec![
                "recovery",
                "flash-invocation",
                "start",
                "--request-file",
                missing,
            ],
            vec![
                "debug",
                "evaluate",
                "--invocation",
                "debug-00000000-0000-4000-8000-000000000000",
                "--action-file",
                missing,
                "--source-sha256",
                &"0".repeat(64),
                "--build-sha256",
                &"0".repeat(64),
            ],
        ] {
            // Nothing listens at the socket: the leaf must refuse before it
            // would connect.
            let output = std::process::Command::new(env!("CARGO_BIN_EXE_arkdeck"))
                .args(&argv)
                .args([
                    "--socket",
                    "/nonexistent/arkdeck-cli-broker.sock",
                    "--output",
                    "json",
                ])
                .output()
                .unwrap();
            let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(output.status.code(), Some(74), "{envelope}");
            assert_eq!(envelope["error"]["code"], "ioFailure");
            assert_eq!(
                envelope["error"]["message"],
                format!("cannot read {missing}")
            );
        }
    }
}
