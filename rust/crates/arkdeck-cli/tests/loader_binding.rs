//! `arkdeck flash bind-loader` against a fake Runtime that answers what
//! Swift's daemon answered in the Loader binding oracle
//! (`rust/tests/fixtures/loader-binding`): the leaf sends exactly its one
//! request, `flash.bind-current-loader` with the revision as an integer, and
//! emits the Runtime's receipt or refusal.
// The fake Runtime this leaf is driven against is a Unix socket.
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
                    .join("../../tests/fixtures/loader-binding/cases.json"),
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

    fn bind(answer: &Value) -> (std::process::Output, Value) {
        support::run_session(
            &[
                "flash",
                "bind-loader",
                "--target",
                "TGT-BOARD-A",
                "--expected-binding-revision",
                "1",
            ],
            vec![
                health(),
                (
                    "flash.bind-current-loader".to_owned(),
                    json!({"targetId":"TGT-BOARD-A","expectedBindingRevision":1}),
                    answer.clone(),
                ),
            ],
        )
    }

    #[test]
    fn bind_loader_sends_the_selected_target_and_its_revision_and_emits_the_receipt() {
        let answer = recorded("bind.firstCrossMode");
        let (output, envelope) = bind(&answer);
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        assert_eq!(envelope["command"], "flash.bind-loader");
        assert_eq!(envelope["result"], answer["result"]);
        assert!(envelope["meta"].get("lifecycle").is_none());

        // A refusal is the Runtime's own, in the CLI's vocabulary (Swift's
        // `CLIControlFailureMapper`), with the Runtime's words: a `rejected`
        // without the pre-admission proof leaves this mutation-capable
        // method's outcome unknown.
        let refused = recorded("bind.lineageAmbiguous");
        let (output, envelope) = bind(&refused);
        assert_ne!(output.status.code(), Some(0));
        assert_eq!(envelope["ok"], false);
        assert_eq!(envelope["error"]["code"], "outcomeUnknown");
        assert_eq!(envelope["error"]["message"], refused["error"]["message"]);
    }
}
