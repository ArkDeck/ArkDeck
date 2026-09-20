//! `arkdeck runtime health` against a fake Runtime: the contract preflight is
//! the call, as it is in Swift's client (`verifyContract: method != "health"`),
//! and the answer is the Runtime's own health document in Swift's envelope.
// The fake Runtime these leaves are driven against is a Unix socket.
#[cfg(target_os = "macos")]
mod support;

#[cfg(target_os = "macos")]
mod runtime {
    use super::support;
    use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
    use serde_json::{Value, json};

    fn health() -> Value {
        json!({"status":"ok","protocolVersion":PROTOCOL_VERSION,"contractIdentity":CONTRACT_IDENTITY,
            "catalogDigest":CATALOG_DIGEST,"providers":["hdc"],"publishedMethods":METHODS})
    }

    #[test]
    fn health_is_one_exchange_and_the_runtimes_own_document() {
        let (output, envelope) = support::run_session(
            &["runtime", "health"],
            // One exchange: a second `health` here would fail the harness.
            vec![(
                "health".to_owned(),
                Value::Null,
                json!({"ok":true,"result":health()}),
            )],
        );
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(envelope["command"], "runtime.health");
        assert_eq!(envelope["ok"], true);
        assert_eq!(envelope["result"], health());
        assert_eq!(envelope["meta"]["controlProtocolVersion"], PROTOCOL_VERSION);
        // The leaf sends no parameters at all, as Swift's `health` request does.
        assert_eq!(envelope["result"]["providers"], json!(["hdc"]));
    }

    #[test]
    fn a_health_document_off_the_contract_is_refused_as_a_protocol_failure() {
        let mut wrong = health();
        wrong["contractIdentity"] = json!("a".repeat(64));
        let (output, envelope) = support::run_session(
            &["runtime", "health"],
            vec![(
                "health".to_owned(),
                Value::Null,
                json!({"ok":true,"result":wrong}),
            )],
        );
        assert_eq!(output.status.code(), Some(70));
        assert_eq!(envelope["ok"], false);
        assert_eq!(envelope["command"], "runtime.health");
        assert_eq!(envelope["error"]["code"], "protocolMalformed");
    }
}
