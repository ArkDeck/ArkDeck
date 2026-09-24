//! `arkdeck flash bootloader-status` and `arkdeck flash prerequisites`
//! against a fake Runtime that answers what Swift's daemon answered in the
//! Flash host facts oracle (`rust/tests/fixtures/flash-host-facts`): each leaf
//! sends exactly its one request, the profile under the Runtime's name for
//! it, and emits the Runtime's answer.
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
                    .join("../../tests/fixtures/flash-host-facts/cases.json"),
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
    fn bootloader_status_sends_no_parameters_and_emits_the_disposition() {
        // An answer the merge base's contract publishes too, so that the
        // published view's run of this test reads the same envelope.
        let answer = recorded("status.loaderUnbound");
        let (output, envelope) = support::run_session(
            &["flash", "bootloader-status"],
            vec![
                health(),
                (
                    "flash.bootloader-status".to_owned(),
                    Value::Null,
                    answer.clone(),
                ),
            ],
        );
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        assert_eq!(envelope["command"], "flash.bootloader-status");
        assert_eq!(envelope["result"], answer["result"]);
        assert!(envelope["meta"].get("lifecycle").is_none());

        // A refusal is the Runtime's own, in the CLI's vocabulary, with the
        // Runtime's words.
        let refused = recorded("status.registryUnavailable");
        let (output, envelope) = support::run_session(
            &["flash", "bootloader-status"],
            vec![
                health(),
                (
                    "flash.bootloader-status".to_owned(),
                    Value::Null,
                    refused.clone(),
                ),
            ],
        );
        assert_ne!(output.status.code(), Some(0));
        assert_eq!(envelope["error"]["code"], "operationFailed");
        assert_eq!(envelope["error"]["message"], refused["error"]["message"]);
    }

    #[test]
    fn prerequisites_send_the_profile_as_the_runtimes_profile_reference() {
        let answer = recorded("prerequisites.hdcReady");
        let (output, envelope) = support::run_session(
            &[
                "flash",
                "prerequisites",
                "--target",
                "TGT-HOST",
                "--device-profile",
                "dayu200",
            ],
            vec![
                health(),
                (
                    "flash.prerequisites".to_owned(),
                    json!({"targetId":"TGT-HOST","profileReference":"dayu200"}),
                    answer.clone(),
                ),
            ],
        );
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        assert_eq!(envelope["command"], "flash.prerequisites");
        assert_eq!(envelope["result"], answer["result"]);

        // Which profiles are supported is the Runtime's to judge; its
        // refusals reach the caller as they are.
        for (name, target, profile, code) in [
            (
                "prerequisites.notAdopted",
                "TGT-ABSENT",
                "dayu200",
                "resourceNotFound",
            ),
            (
                "prerequisites.unsupportedProfile",
                "TGT-HOST",
                "rk3568-generic",
                "invalidInput",
            ),
        ] {
            let refused = recorded(name);
            let (output, envelope) = support::run_session(
                &[
                    "flash",
                    "prerequisites",
                    "--target",
                    target,
                    "--device-profile",
                    profile,
                ],
                vec![
                    health(),
                    (
                        "flash.prerequisites".to_owned(),
                        json!({"targetId":target,"profileReference":profile}),
                        refused.clone(),
                    ),
                ],
            );
            assert_ne!(output.status.code(), Some(0), "{name}");
            assert_eq!(envelope["error"]["code"], code, "{name}");
            assert_eq!(envelope["error"]["message"], refused["error"]["message"]);
        }
    }

    #[test]
    fn prerequisites_without_both_options_never_reach_the_runtime() {
        for (argv, message) in [
            (
                vec!["flash", "prerequisites", "--device-profile", "dayu200"],
                "flash prerequisites requires --target",
            ),
            (
                vec!["flash", "prerequisites", "--target", "TGT-HOST"],
                "flash prerequisites requires --device-profile",
            ),
        ] {
            let output = std::process::Command::new(env!("CARGO_BIN_EXE_arkdeck"))
                .args(&argv)
                .args(["--output", "json", "--socket", "/nonexistent/arkdeck.sock"])
                .output()
                .unwrap();
            assert_eq!(output.status.code(), Some(64), "{argv:?}");
            let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(envelope["command"], "flash.prerequisites");
            assert_eq!(envelope["error"]["code"], "invalidOption");
            assert_eq!(envelope["error"]["message"], message);
        }
    }
}
