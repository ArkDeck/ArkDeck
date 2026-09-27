//! Replay actual Swift process observations, including options owned by leaves.
use serde_json::Value;
use std::process::Command;

fn label(text: &str, identity: &str) -> String {
    let mut text = text.replace(identity, "sha256:<executable>");
    // Only generated UUID correlations may differ between actual processes.
    while let Some(start) = text.find("ctl-").filter(|&start| {
        text.get(start + 4..start + 40).is_some_and(|uuid| {
            uuid.bytes().enumerate().all(|(i, byte)| {
                if [8, 13, 18, 23].contains(&i) {
                    byte == b'-'
                } else {
                    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
                }
            })
        })
    }) {
        text.replace_range(start..start + 40, "ctl-<uuid>");
    }
    text
}

#[test]
fn version_matches_actual_swift_and_hashes_the_running_executable() {
    let executable = env!("CARGO_BIN_EXE_arkdeck");
    let identity = format!(
        "sha256:{}",
        arkdeck_contract::sha256_hex(&std::fs::read(executable).unwrap())
    );
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/cli-version/cases.json"
    ))
    .unwrap();
    for run in fixture["runs"].as_array().unwrap() {
        let argv: Vec<_> = run["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        let output = Command::new(executable)
            .args(&argv)
            .env("ARKDECK_ENDPOINT", "/version-must-not-connect")
            .output()
            .unwrap();
        assert_eq!(
            output.status.code(),
            Some(run["exitCode"].as_i64().unwrap() as i32),
            "{argv:?}"
        );
        let stdout = String::from_utf8(output.stdout).unwrap();
        if run["stdout"]
            .as_str()
            .unwrap()
            .contains("sha256:<executable>")
        {
            assert!(
                stdout.contains(&identity),
                "must hash this executable: {argv:?}"
            );
        }
        if argv == ["doctor", "--help", "--version"] {
            // Help wins over version. Rust already owns different transport
            // prose/option formatting; preserve its entire normal help output.
            let help = Command::new(executable)
                .args(["doctor", "--help"])
                .output()
                .unwrap();
            assert!(help.status.success());
            assert_eq!(stdout.as_bytes(), help.stdout, "help precedence");
        } else {
            assert_eq!(label(&stdout, &identity), run["stdout"], "stdout: {argv:?}");
        }
        assert_eq!(
            label(&String::from_utf8(output.stderr).unwrap(), &identity),
            run["stderr"],
            "stderr: {argv:?}"
        );
    }
}

#[test]
fn leaf_owned_version_keeps_existing_leading_option_refusals() {
    let tail = [
        "maintainer",
        "update-feed",
        "prepare",
        "--version",
        "1.2.3",
        "--output",
        "json",
    ];
    for option in ["--control-request-id", "--socket", "--timeout"] {
        let value = match option {
            "--timeout" => "2s",
            "--socket" => "/missing",
            _ => "ctl-explicit",
        };
        let before: Vec<String> = [option, value]
            .into_iter()
            .chain(tail)
            .map(str::to_owned)
            .collect();
        let after: Vec<String> = tail
            .into_iter()
            .chain([option, value])
            .map(str::to_owned)
            .collect();
        let leading = arkdeck_cli::parse(&before).unwrap_err();
        let trailing = arkdeck_cli::parse(&after).unwrap_err();
        assert_eq!(leading.code, trailing.code, "{option}");
        assert_eq!(leading.message, trailing.message, "{option}");
        assert_eq!(leading.details, trailing.details, "{option}");
        assert_eq!(leading.command, trailing.command, "{option}");
    }
}
