#![cfg(target_os = "macos")]
use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Read, Write},
    os::unix::{
        fs::{DirBuilderExt, PermissionsExt},
        net::UnixListener,
    },
    process::Command,
};

fn portrait() -> Value {
    json!({"schemaVersion":"arkdeck.debug-probe/1", "targetId":"target-fixture", "bindingRevision":3,
        "packages":["com.example.a"], "portRules":[{"direction":"forward","localPort":1234,"remotePort":5678}],
        "warnings":["reverseRulesUnavailable"]})
}

#[test]
fn actual_cli_verifies_identity_sends_one_target_only_probe_and_preserves_warning_facts() {
    for case in [
        "json",
        "human",
        "legacy",
        "foreign-target",
        "invalid-port",
        "unsorted-packages",
        "unknown-warning",
        "remote-error",
        "lost-reply",
        "wrong-identity",
    ] {
        let root = std::path::PathBuf::from(format!(
            "/private/tmp/debug-cli-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let path = root.join("a.sock");
        let listener = UnixListener::bind(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let acceptor = listener.try_clone().unwrap();
        let server = std::thread::spawn(move || {
            let (stream, _) = acceptor.accept().unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let health: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(health["method"], "health");
            let identity = if case == "wrong-identity" {
                "wrong"
            } else {
                CONTRACT_IDENTITY
            };
            writeln!(reader.get_mut(), "{}", json!({"id":"health","ok":true,"result":{"status":"ok","protocolVersion":PROTOCOL_VERSION,
                "contractIdentity":identity,"catalogDigest":CATALOG_DIGEST,"providers":[],"publishedMethods":METHODS}})).unwrap();
            line.clear();
            if case == "wrong-identity" {
                assert_eq!(reader.read_line(&mut line).unwrap(), 0);
                return;
            }
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], "debug.probe");
            assert_eq!(request["params"], json!({"targetId":"target-fixture"}));
            assert_eq!(request["id"], "probe-cli");
            if case == "lost-reply" {
                return;
            }
            let mut result = portrait();
            match case {
                "foreign-target" => result["targetId"] = json!("another-target"),
                "invalid-port" => result["portRules"][0]["localPort"] = json!(0),
                "unsorted-packages" => result["packages"] = json!(["com.z", "com.a"]),
                "unknown-warning" => result["warnings"] = json!(["invented"]),
                _ => (),
            }
            let answer = if case == "remote-error" {
                json!({"id":request["id"],"ok":false,"error":{"code":"rejected","message":"target binding unavailable"}})
            } else {
                json!({"id":request["id"],"ok":true,"result":result})
            };
            writeln!(reader.get_mut(), "{answer}").unwrap();
            let mut extra = Vec::new();
            reader.read_to_end(&mut extra).unwrap();
            assert!(extra.is_empty(), "no replay or Job creation");
        });
        let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck"));
        command
            .args([
                "debug",
                "probe",
                "--target",
                "target-fixture",
                "--control-request-id",
                "probe-cli",
                "--socket",
            ])
            .arg(&path);
        if case == "legacy" {
            command.arg("--json");
        } else {
            command.args(["--output", if case == "human" { "human" } else { "json" }]);
        }
        let output = command.output().unwrap();
        server.join().unwrap();
        let answer: Value = serde_json::from_slice(&output.stdout).unwrap();
        // The legacy `--json` answer is Swift's legacy document, byte for byte.
        if case == "legacy" {
            assert_eq!(
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&arkdeck_cli::legacy_document(&portrait()))
            );
        }
        if matches!(case, "json" | "human" | "legacy") {
            assert!(output.status.success(), "{case}: {answer}");
            assert_eq!(
                if case == "json" {
                    &answer["result"]
                } else {
                    &answer
                },
                &portrait()
            );
        } else {
            assert!(!output.status.success(), "{case}: {answer}");
            assert!(answer.get("result").is_none(), "{case}: {answer}");
            if matches!(
                case,
                "foreign-target" | "invalid-port" | "unsorted-packages" | "unknown-warning"
            ) {
                assert_eq!(answer["error"]["code"], "recordUnreadable", "{case}");
            }
        }
        listener.set_nonblocking(true).unwrap();
        assert!(matches!(listener.accept(), Err(e) if e.kind() == std::io::ErrorKind::WouldBlock));
        drop(listener);
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn probe_refuses_execution_inputs_and_conflicting_modes_before_connection() {
    for extra in [
        vec!["--raw-command", "shell uptime"],
        vec!["--capability", "anything"],
        vec!["--template", "device.uptime"],
        vec!["--timeout", "1s"],
        vec!["--json", "--output", "json"],
        vec!["--output", "jsonl"],
    ] {
        let mut args = vec!["debug", "probe", "--target", "target-fixture"];
        args.extend(extra);
        assert!(
            arkdeck_cli::parse(&args.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>()).is_err()
        );
    }
    for target in [String::new(), "t".repeat(129)] {
        assert!(
            arkdeck_cli::parse(&["debug".into(), "probe".into(), "--target".into(), target])
                .is_err()
        );
    }
}
