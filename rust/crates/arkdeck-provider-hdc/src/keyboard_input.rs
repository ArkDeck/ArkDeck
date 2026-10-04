//! One private, default-display UiTest key/text action. Exact positive UiTest
//! acknowledgement confirms injector acceptance, never application text state.
//! Uncertain/partial receipts cannot be reconciled by repeating input.
use crate::{Outcome, ProcessPlan, Receipt, ResolvedArtifact};
use arkdeck_contract::{KEYBOARD_PAYLOAD_MAX_BYTES, KeyboardPayload, sha256_hex};
use serde_json::{Map, Value, json};
use std::{collections::BTreeMap, io::Read, time::Duration};

pub struct KeyboardInput {
    payload: KeyboardPayload,
    artifact_id: String,
    sha256: String,
}

impl KeyboardInput {
    pub fn from_artifact(
        artifact: &ResolvedArtifact,
        epoch: &str,
        now: &str,
    ) -> Result<Self, String> {
        let captured = crate::pointer_input::utc_nanoseconds(epoch);
        let current = crate::pointer_input::utc_nanoseconds(now);
        if !matches!((captured, current), (Some(a), Some(b)) if b >= a && b-a <= 10_000_000_000) {
            return Err(
                "inputExpired: keyboard intent is invalid or older than ten seconds".into(),
            );
        }
        let mut bytes = Vec::new();
        std::fs::File::open(&artifact.path)
            .and_then(|file| {
                file.take(KEYBOARD_PAYLOAD_MAX_BYTES as u64 + 1)
                    .read_to_end(&mut bytes)
            })
            .map_err(|_| "keyboard Artifact is unreadable".to_string())?;
        if sha256_hex(&bytes) != artifact.sha256 {
            return Err("keyboard Artifact integrity check failed".into());
        }
        let payload = KeyboardPayload::decode(&bytes)
            .map_err(|_| "keyboard Artifact is invalid".to_string())?;
        Ok(Self {
            payload,
            artifact_id: artifact.artifact_id.clone(),
            sha256: artifact.sha256.clone(),
        })
    }

    pub fn persisted(&self) -> (&'static str, Map<String, Value>) {
        (
            "hdc.injectKeyboardInput",
            Map::from_iter([
                ("sourceArtifactId".into(), json!(self.artifact_id)),
                ("sourceSha256".into(), json!(self.sha256)),
            ]),
        )
    }

    pub fn plan(&self, connect_key: &str) -> ProcessPlan {
        let mut arguments = vec![
            "-t".into(),
            connect_key.into(),
            "shell".into(),
            "uitest".into(),
            "uiInput".into(),
        ];
        match &self.payload {
            KeyboardPayload::Key { key } => {
                arguments.extend(["keyEvent".into(), key.code().to_string()])
            }
            KeyboardPayload::Text { text, .. } => {
                // HDC adds another quote layer around argv containing spaces.
                // All bytes are octal data and this fixed expansion contains no
                // literal spaces: one UTF-8 argument survives both boundaries.
                // Caller characters can never become remote shell syntax.
                let octal: String = text.bytes().map(|b| format!("\\0{b:03o}")).collect();
                arguments.extend([
                    "text".into(),
                    format!("\"$(printf${{IFS}}%b${{IFS}}'{octal}')\""),
                ]);
            }
        }
        ProcessPlan {
            arguments,
            timeout: Duration::from_secs(30),
            capture_bytes: 4096,
        }
    }

    pub fn verify(&self, receipt: &Receipt) -> Outcome {
        if receipt.exit_status == 0
            && !receipt.truncated
            && receipt.stderr.is_empty()
            && matches!(receipt.stdout.as_slice(), b"No Error\n" | b"No Error\r\n")
        {
            Outcome::Verified(BTreeMap::from([(
                "keyboardInput".into(),
                "injectorAccepted".into(),
            )]))
        } else {
            // The tool may print a message containing input. Never interpolate
            // either stream, a command or the input, even in error diagnostics.
            Outcome::Unknown(
                "keyboard injector acknowledgement unavailable; input is never replayed".into(),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::process::Command;

    fn input(text: &str) -> KeyboardInput {
        KeyboardInput {
            payload: KeyboardPayload::Text {
                text: text.into(),
                allow_device_clipboard: true,
            },
            artifact_id: "private-input".into(),
            sha256: "a".repeat(64),
        }
    }
    #[test]
    fn receipts_need_exact_positive_ack_and_never_echo_private_bytes() {
        let action = input("private fixture");
        let mut receipt = Receipt {
            exit_status: 0,
            stdout: b"No Error\n".to_vec(),
            stderr: vec![],
            truncated: false,
            duration: Duration::ZERO,
        };
        assert!(matches!(action.verify(&receipt), Outcome::Verified(_)));
        for output in [
            b"".as_slice(),
            b"No Error",
            b"No Error\nprivate fixture",
            b"private fixture",
        ] {
            receipt.stdout = output.to_vec();
            let answer = action.verify(&receipt);
            assert!(matches!(answer, Outcome::Unknown(_)));
            assert!(!format!("{answer:?}").contains("private fixture"));
        }
        receipt.stdout = b"No Error\n".to_vec();
        receipt.truncated = true;
        assert!(matches!(action.verify(&receipt), Outcome::Unknown(_)));
        assert_eq!(action.persisted().1.len(), 2);
        assert!(
            !serde_json::to_string(&action.persisted().1)
                .unwrap()
                .contains("private fixture")
        );
    }
    #[test]
    #[cfg(unix)]
    fn hdc_argument_join_preserves_unicode_and_shell_metacharacters_as_one_literal_argument() {
        // Local shell fixture only: emulate HDC's documented argv join, then
        // replace the device executable with a function reporting argv bytes.
        for value in [
            "你好 世界",
            " a  b ",
            "'\"`$()\\;|&<>*?[]{}",
            "$(exit 91)",
            "100% done",
        ] {
            let plan = input(value).plan("bound-key");
            assert!(plan.arguments.iter().skip(3).all(|arg| !arg.contains(' ')));
            let remote = plan.arguments[3..].join(" ");
            let script = format!(
                "uitest() {{ test \"$#\" -eq 3 || exit 92; printf '%s' \"$3\"; }}; {remote}"
            );
            let result = Command::new("/bin/sh")
                .args(["-c", &script])
                .output()
                .unwrap();
            assert!(result.status.success());
            assert!(result.stderr.is_empty());
            assert_eq!(result.stdout, value.as_bytes());
        }
    }
}
