//! `arkdeck flash reconcile-alias`, `arkdeck recovery flash-invocation
//! list|status` and the legacy `arkdeck debug status` against a fake Runtime
//! that answers what Swift's daemon answered in the Flash host reads oracle
//! (`rust/tests/fixtures/flash-host-reads`): each leaf sends exactly its one
//! request and emits the Runtime's answer, and the legacy leaf says what
//! replaces it.
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

    /// The recorded answer of one oracle exchange, by name.
    fn recorded(name: &str) -> Value {
        let cases: Value = serde_json::from_slice(
            &std::fs::read(
                std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../../tests/fixtures/flash-host-reads/cases.json"),
            )
            .unwrap(),
        )
        .unwrap();
        cases["exchanges"]
            .as_array()
            .unwrap()
            .iter()
            .find(|exchange| exchange["name"] == name)
            .unwrap_or_else(|| panic!("the oracle recorded {name}"))["answer"]
            .clone()
    }

    #[test]
    fn reconcile_alias_sends_its_typed_revision_and_emits_the_receipt() {
        let answer = recorded("alias.reconciled");
        let (output, envelope) = support::run_session(
            &[
                "flash",
                "reconcile-alias",
                "--target",
                "TGT-HOST",
                "--expected-binding-revision",
                "2",
            ],
            vec![
                health(),
                (
                    "flash.reconcile-alias".to_owned(),
                    json!({"targetId":"TGT-HOST","expectedBindingRevision":2}),
                    answer.clone(),
                ),
            ],
        );
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        assert_eq!(envelope["command"], "flash.reconcile-alias");
        assert_eq!(envelope["result"], answer["result"]);
        assert!(envelope["meta"].get("lifecycle").is_none());

        // A refusal is the Runtime's own, in the CLI's vocabulary (Swift's
        // `CLIControlFailureMapper`), with the Runtime's words.
        let refused = recorded("alias.repeated");
        let (output, envelope) = support::run_session(
            &[
                "flash",
                "reconcile-alias",
                "--target",
                "TGT-HOST",
                "--expected-binding-revision",
                "2",
            ],
            vec![
                health(),
                (
                    "flash.reconcile-alias".to_owned(),
                    json!({"targetId":"TGT-HOST","expectedBindingRevision":2}),
                    refused.clone(),
                ),
            ],
        );
        assert_ne!(output.status.code(), Some(0));
        assert_eq!(envelope["ok"], false);
        assert_eq!(envelope["error"]["code"], "operationFailed");
        assert_eq!(envelope["error"]["message"], refused["error"]["message"]);
    }

    #[test]
    fn the_invocation_list_sends_its_page_and_cursor() {
        let page = recorded("list.all");
        for (argv, params) in [
            (
                vec!["recovery", "flash-invocation", "list"],
                json!({"pageSize":100}),
            ),
            (
                vec![
                    "recovery",
                    "flash-invocation",
                    "list",
                    "--page-size",
                    "4",
                    "--cursor",
                    "opaque-cursor",
                ],
                json!({"pageSize":4,"cursor":"opaque-cursor"}),
            ),
        ] {
            let mut answer = page.clone();
            answer["result"]["snapshotRevision"] = json!("6f16efd0-6556-410a-ab39-eb41545a4634");
            let (output, envelope) = support::run_session(
                &argv,
                vec![
                    health(),
                    (
                        "recovery.flash-invocation.list".to_owned(),
                        params,
                        answer.clone(),
                    ),
                ],
            );
            assert_eq!(output.status.code(), Some(0), "{envelope}");
            assert_eq!(envelope["result"], answer["result"]);
        }
        // The page size is judged before any request.
        for size in ["0", "1001", "four"] {
            let error = arkdeck_cli::parse(
                &["recovery", "flash-invocation", "list", "--page-size", size].map(str::to_owned),
            )
            .unwrap_err();
            assert_eq!(
                (error.code, error.exit_code()),
                ("invalidOption", 64),
                "{size}"
            );
        }
    }

    #[test]
    fn both_status_spellings_read_debug_status_and_the_legacy_one_says_what_replaces_it() {
        // An observed evaluation: a shape the published view's schema
        // admits as well as this checkout's.
        let status = recorded("status.observed");
        let identity = status["result"]["invocationID"]
            .as_str()
            .unwrap()
            .to_owned();
        for (argv, command, legacy) in [
            (
                vec!["recovery", "flash-invocation", "status", "--invocation"],
                "recovery.flash-invocation.status",
                false,
            ),
            (
                vec!["debug", "status", "--invocation"],
                "debug.status",
                true,
            ),
        ] {
            let mut argv = argv;
            argv.push(&identity);
            let (output, envelope) = support::run_session(
                &argv,
                vec![
                    health(),
                    (
                        "debug.status".to_owned(),
                        json!({"invocationId": identity}),
                        status.clone(),
                    ),
                ],
            );
            assert_eq!(output.status.code(), Some(0), "{envelope}");
            assert_eq!(envelope["command"], command);
            assert_eq!(envelope["result"], status["result"]);
            assert_eq!(
                envelope["meta"].get("lifecycle").cloned(),
                legacy.then(|| json!({
                    "status": "legacy",
                    "replacementArgvPattern":
                        "arkdeck recovery flash-invocation status --invocation <id>",
                    "removalVersion": null,
                })),
                "{command}"
            );
        }
        // A refusal of the legacy spelling carries the same lifecycle.
        let missing = recorded("status.unknown");
        let (output, envelope) = support::run_session(
            &[
                "debug",
                "status",
                "--invocation",
                "debug-00000000-0000-4000-8000-000000000000",
            ],
            vec![
                health(),
                (
                    "debug.status".to_owned(),
                    json!({"invocationId":"debug-00000000-0000-4000-8000-000000000000"}),
                    missing,
                ),
            ],
        );
        assert_ne!(output.status.code(), Some(0));
        assert_eq!(envelope["error"]["code"], "resourceNotFound");
        assert_eq!(envelope["meta"]["lifecycle"]["status"], "legacy");
        // Parse failures of the legacy leaf name it too.
        let output = std::process::Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(["debug", "status", "--output", "json"])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(64));
        let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(envelope["command"], "debug.status");
        assert_eq!(envelope["meta"]["lifecycle"]["status"], "legacy");
    }

    #[test]
    fn the_human_rendering_warns_of_the_legacy_spelling_on_stderr() {
        let status = recorded("status.active");
        let identity = status["result"]["invocationID"]
            .as_str()
            .unwrap()
            .to_owned();
        let (output, _) = support::run_session(
            &[
                "debug",
                "status",
                "--invocation",
                &identity,
                "--output",
                "human",
            ],
            vec![
                health(),
                (
                    "debug.status".to_owned(),
                    json!({"invocationId": identity}),
                    status,
                ),
            ],
        );
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(
            String::from_utf8(output.stderr).unwrap(),
            "warning: `debug status` is legacy; use `arkdeck recovery flash-invocation status \
             --invocation <id>`\n"
        );
    }
}
