//! `arkdeck operation validate` against a fake Runtime, judged against a
//! descriptor Swift recorded (`Fixtures/ControlFrames/operation.describe.jsonl`):
//! the descriptor answers first, the typed inputs are read and judged against
//! it, and the digest that judged them is read on the same connection. The
//! answer is emitted whatever the findings say, and the findings decide the
//! exit.
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

    /// The recorded `operation.describe` answer for `input.swipe@1`, as Swift's
    /// Runtime published it.
    fn descriptor() -> Value {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(
            "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/operation.describe.jsonl",
        );
        std::fs::read_to_string(path)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .find(|row| row["params"]["reference"] == "input.swipe@1" && row["ok"] == true)
            .expect("the recorded input.swipe@1 descriptor")["result"]
            .clone()
    }

    fn inputs_file(body: &str) -> (std::path::PathBuf, String) {
        let root = std::path::PathBuf::from(format!(
            "/private/tmp/arkdeck-cli-validate-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::create_dir(&root).unwrap();
        let path = root.join("inputs.json");
        std::fs::write(&path, body).unwrap();
        let text = path.to_str().unwrap().to_owned();
        (root, text)
    }

    fn exchanges(reference: &str, descriptor: Value) -> Vec<(String, Value, Value)> {
        vec![
            (
                "health".to_owned(),
                Value::Null,
                json!({"ok":true,"result":health()}),
            ),
            (
                "operation.describe".to_owned(),
                json!({"reference": reference}),
                json!({"ok":true,"result":descriptor}),
            ),
            (
                "health".to_owned(),
                Value::Null,
                json!({"ok":true,"result":health()}),
            ),
        ]
    }

    #[test]
    fn inputs_the_descriptor_accepts_are_structurally_valid_and_name_the_digest() {
        let fields = descriptor()["inputs"].as_array().unwrap().clone();
        let required: Vec<&str> = fields
            .iter()
            .filter(|field| field["required"] == json!(true))
            .map(|field| field["name"].as_str().unwrap())
            .collect();
        assert!(required.contains(&"displayHeight"), "{required:?}");
        let document = json!({"displayWidth":1080,"displayHeight":2340,"fromX":10,"fromY":20,
            "toX":30,"toY":40,"durationMs":100});
        for name in &required {
            assert!(document.get(name).is_some(), "the recorded {name} is unset");
        }
        let (root, path) = inputs_file(&document.to_string());
        let (output, envelope) = support::run_session(
            &[
                "operation",
                "validate",
                "--operation",
                "input.swipe@1",
                "--inputs-file",
                &path,
            ],
            exchanges("input.swipe@1", descriptor()),
        );
        std::fs::remove_dir_all(root).unwrap();
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(envelope["command"], "operation.validate");
        assert_eq!(
            envelope["result"],
            json!({"reference":"input.swipe@1","structurallyValid":true,"findings":[],
                "checkedAgainst":{"runtimeCatalogDigest":CATALOG_DIGEST,
                    "scope":"publishedInputContract"}})
        );
    }

    #[test]
    fn findings_are_reported_after_the_answer_and_decide_the_exit() {
        let (root, path) = inputs_file(r#"{"displayWidth":"1080","nope":true}"#);
        let (output, envelope) = support::run_session(
            &[
                "operation",
                "validate",
                "--operation",
                "input.swipe@1",
                "--inputs-file",
                &path,
            ],
            exchanges("input.swipe@1", descriptor()),
        );
        std::fs::remove_dir_all(root).unwrap();
        // The caller asked what the descriptor says, and it answered: the document
        // is on stdout, `ok:true`, and the problems are named on stderr.
        assert_eq!(envelope["ok"], true);
        assert_eq!(envelope["result"]["structurallyValid"], false);
        let findings = envelope["result"]["findings"].as_array().unwrap();
        let codes: Vec<&str> = findings
            .iter()
            .map(|finding| finding["code"].as_str().unwrap())
            .collect();
        assert!(codes.contains(&"typeMismatch"), "{findings:?}");
        assert!(codes.contains(&"missingRequired"), "{findings:?}");
        assert_eq!(codes.last(), Some(&"unknownField"), "{findings:?}");
        assert_eq!(output.status.code(), Some(65));
        assert!(
            String::from_utf8_lossy(&output.stderr).contains(&format!(
                "{} input problems for input.swipe@1",
                findings.len()
            )),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn the_document_is_read_after_the_descriptor_answers() {
        // Swift asks the Runtime first and reads the file second, so an unreadable
        // file is refused only once the descriptor is in hand — the exchange the
        // harness requires here proves the order.
        let (output, envelope) = support::run_session(
            &[
                "operation",
                "validate",
                "--operation",
                "input.swipe@1",
                "--inputs-file",
                "/private/tmp/arkdeck-cli-validate-missing/inputs.json",
            ],
            exchanges("input.swipe@1", descriptor())
                .into_iter()
                .take(2)
                .collect(),
        );
        assert_eq!(output.status.code(), Some(74));
        assert_eq!(envelope["error"]["code"], "ioFailure");
        assert_eq!(envelope["command"], "operation.validate");
    }

    #[test]
    fn a_descriptor_without_an_input_contract_never_reaches_the_check() {
        let (root, path) = inputs_file("{}");
        let mut without = descriptor();
        without.as_object_mut().unwrap().remove("inputs");
        let (output, envelope) = support::run_session(
            &[
                "operation",
                "validate",
                "--operation",
                "input.swipe@1",
                "--inputs-file",
                &path,
            ],
            exchanges("input.swipe@1", without)
                .into_iter()
                .take(2)
                .collect(),
        );
        std::fs::remove_dir_all(root).unwrap();
        // Swift's own guard answers `recordUnreadable` here, and this port keeps
        // it, but this client cannot reach it: `inputs` is required by the
        // published `operation.describe` result, so a descriptor without it is
        // refused as a malformed answer before the leaf sees it. The guard stays
        // for the day that contract loosens.
        assert_eq!(output.status.code(), Some(70));
        assert_eq!(envelope["error"]["code"], "protocolMalformed");
        assert_eq!(envelope["command"], "operation.validate");
    }

    #[test]
    fn a_dash_reads_the_document_from_stdin_rather_than_a_file_called_dash() {
        // The CLI runs with no stdin here, so the document is empty: a file named
        // `-` would be missing instead, and that is `ioFailure`.
        let (output, envelope) = support::run_session(
            &[
                "operation",
                "validate",
                "--operation",
                "input.swipe@1",
                "--inputs-file",
                "-",
            ],
            exchanges("input.swipe@1", descriptor())
                .into_iter()
                .take(2)
                .collect(),
        );
        assert_eq!(output.status.code(), Some(65));
        assert_eq!(envelope["error"]["code"], "invalidInput");
        assert_eq!(
            envelope["error"]["message"],
            "typed inputs are not one valid JSON document"
        );
    }

    #[test]
    fn a_runtime_that_cannot_name_its_digest_still_answers_the_structural_question() {
        let (root, path) = inputs_file(
            &json!({"displayWidth":1080,"displayHeight":2340,"fromX":10,"fromY":20,
                "toX":30,"toY":40,"durationMs":100})
            .to_string(),
        );
        let mut exchanges = exchanges("input.swipe@1", descriptor());
        exchanges[2].2 = json!({"ok":false,"error":{"code":"internalError","message":"no"}});
        let (output, envelope) = support::run_session(
            &[
                "operation",
                "validate",
                "--operation",
                "input.swipe@1",
                "--inputs-file",
                &path,
            ],
            exchanges,
        );
        std::fs::remove_dir_all(root).unwrap();
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(envelope["result"]["structurallyValid"], true);
        assert_eq!(
            envelope["result"]["checkedAgainst"]["runtimeCatalogDigest"],
            Value::Null
        );
    }
}
