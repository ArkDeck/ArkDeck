//! `arkdeck flash bootloader-status`, `arkdeck flash prerequisites`,
//! `arkdeck flash lane-preview` and `arkdeck flash device-access` against a
//! fake Runtime that answers what Swift's daemon answered (the Flash host
//! facts oracle, `rust/tests/fixtures/flash-host-facts`, and the committed
//! control frames): each leaf sends exactly its one request, the profile under
//! the Runtime's name for it, and emits the Runtime's answer.
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

    /// `flash device-access` sends one request without parameters and emits
    /// the modes as the Runtime answers them (Swift's corpus answer).
    #[test]
    fn device_access_sends_no_parameters_and_emits_the_modes() {
        let answer =
            json!({"ok":true,"result":{"observationCount":2,"observedModes":["Loader","Maskrom"]}});
        let (output, envelope) = support::run_session(
            &["flash", "device-access"],
            vec![
                health(),
                (
                    "flash.device-access".to_owned(),
                    Value::Null,
                    answer.clone(),
                ),
            ],
        );
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        assert_eq!(envelope["command"], "flash.device-access");
        assert_eq!(envelope["result"], answer["result"]);
        let refused = json!({"ok":false,"error":{"code":"rejected",
            "message":"Rockchip device access observation failed"}});
        let (output, envelope) = support::run_session(
            &["flash", "device-access"],
            vec![
                health(),
                (
                    "flash.device-access".to_owned(),
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
                "`flash prerequisites` requires --target <target-id>",
            ),
            (
                vec!["flash", "prerequisites", "--target", "TGT-HOST"],
                "`flash prerequisites` requires --device-profile <dayu200>",
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

    /// `flash lane-preview` sends the profile as the Runtime's
    /// `profileReference` and the archive digest as given, under the 1.x
    /// wire method Swift's handler keeps, and emits every state the Runtime
    /// answers (the answers of Swift's committed control frames).
    #[test]
    fn lane_preview_sends_its_three_parameters_under_the_1x_method() {
        let digest = "e".repeat(64);
        let argv = [
            "flash",
            "lane-preview",
            "--target",
            "TGT-aaaaaaaaaaaa",
            "--device-profile",
            "dayu200",
            "--archive-sha256",
            &digest,
        ];
        let params = json!({"targetId":"TGT-aaaaaaaaaaaa","profileReference":"dayu200",
            "archiveSha256":digest});
        for result in [
            json!({"availability":"unavailable","bindingRevision":1,
                "reason":"maturity is hardwareGated","state":"planNotExecutable",
                "targetId":"TGT-aaaaaaaaaaaa","unknowns":["RK-M02: combination is hardwareGated"]}),
            json!({"bindingRevision":1,"observationMode":"hdc-normal","planId":"PLAN-preview",
                "planSha256":"d".repeat(64),"state":"available","targetId":"TGT-aaaaaaaaaaaa"}),
            json!({"bindingRevision":1,"state":"laneNotComposed","targetId":"TGT-aaaaaaaaaaaa"}),
        ] {
            let (output, envelope) = support::run_session(
                &argv,
                vec![
                    health(),
                    (
                        "flash.lanePlanPreview".to_owned(),
                        params.clone(),
                        json!({"ok":true,"result":result}),
                    ),
                ],
            );
            assert_eq!(output.status.code(), Some(0), "{envelope}");
            assert_eq!(envelope["command"], "flash.lane-preview");
            assert_eq!(envelope["result"], result);
            assert!(envelope["meta"].get("lifecycle").is_none());
        }

        // Which Target and archive the preview names is the Runtime's to
        // judge; its refusal reaches the caller with its words.
        let (output, envelope) = support::run_session(
            &argv,
            vec![
                health(),
                (
                    "flash.lanePlanPreview".to_owned(),
                    params,
                    json!({"ok":false,"error":{"code":"notFound",
                        "message":"target is not adopted"}}),
                ),
            ],
        );
        assert_ne!(output.status.code(), Some(0));
        assert_eq!(envelope["error"]["code"], "resourceNotFound");
        assert_eq!(envelope["error"]["message"], "target is not adopted");
    }

    /// What Swift's registry parser refuses never reaches the Runtime, and is
    /// refused in its words: each required option in the registry's order,
    /// then the digest's grammar, 64 lowercase hex digits (stricter than the
    /// Runtime, which takes any case).
    #[test]
    fn lane_preview_refuses_at_parse_what_swifts_registry_refuses() {
        let digest = "e".repeat(64);
        let upper = "E".repeat(64);
        let short = "e".repeat(63);
        let grammar = "`flash lane-preview` --archive-sha256 must be 64 lowercase hex digits";
        for (options, message) in [
            (
                vec!["--device-profile", "dayu200", "--archive-sha256", &digest],
                "`flash lane-preview` requires --target <target-id>",
            ),
            (
                vec!["--target", "TGT-HOST", "--archive-sha256", &digest],
                "`flash lane-preview` requires --device-profile <dayu200>",
            ),
            (
                vec!["--target", "TGT-HOST", "--device-profile", "dayu200"],
                "`flash lane-preview` requires --archive-sha256 <sha256>",
            ),
            (
                vec![
                    "--target",
                    "TGT-HOST",
                    "--device-profile",
                    "dayu200",
                    "--archive-sha256",
                    &upper,
                ],
                grammar,
            ),
            (
                vec![
                    "--target",
                    "TGT-HOST",
                    "--device-profile",
                    "dayu200",
                    "--archive-sha256",
                    &short,
                ],
                grammar,
            ),
        ] {
            let output = std::process::Command::new(env!("CARGO_BIN_EXE_arkdeck"))
                .args(["flash", "lane-preview"])
                .args(&options)
                .args(["--output", "json", "--socket", "/nonexistent/arkdeck.sock"])
                .output()
                .unwrap();
            assert_eq!(output.status.code(), Some(64), "{options:?}");
            let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(envelope["command"], "flash.lane-preview");
            assert_eq!(envelope["error"]["code"], "invalidOption");
            assert_eq!(envelope["error"]["message"], message);
        }
    }
}
