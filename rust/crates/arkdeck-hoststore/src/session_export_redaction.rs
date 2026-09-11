//! Pure byte redaction used by Session derived export. This module never reads
//! or writes a source/destination and does not authorize export publication.
use std::{collections::BTreeSet, io};

const LIMIT: usize = 64 * 1024 * 1024;
const SENTINEL: &[u8] = b"[REDACTED-DEVICE-ID]";

/// Identifier replacement follows the current Swift export consumer: exact
/// manifest values are redacted even when short; byte substrings need four
/// UTF-8 bytes, prefer the longest match, and never re-scan inserted text.
pub struct SessionExportRedactor {
    identifiers: BTreeSet<String>,
    patterns: Vec<Vec<u8>>,
}
impl SessionExportRedactor {
    pub fn new(identifiers: BTreeSet<String>) -> Self {
        let mut patterns: Vec<_> = identifiers
            .iter()
            .filter(|s| s.len() >= 4)
            .map(|s| s.as_bytes().to_vec())
            .collect();
        // Equal-length patterns cannot both match one input position. The
        // lexical tie-break keeps processing deterministic across processes.
        patterns.sort_by(|a, b| b.len().cmp(&a.len()).then_with(|| a.cmp(b)));
        Self {
            identifiers,
            patterns,
        }
    }

    pub fn artifact_bytes(&self, input: &[u8]) -> io::Result<Vec<u8>> {
        if input.len() > LIMIT {
            return Err(limit_error());
        }
        self.replace(input, SENTINEL, LIMIT)
    }

    pub fn manifest_string(&self, input: &str) -> io::Result<String> {
        if self.identifiers.contains(input) {
            return Ok(String::from_utf8(SENTINEL.to_vec()).expect("ASCII sentinel"));
        }
        let bytes = self.replace(input.as_bytes(), b"[R]", LIMIT)?;
        // Every pattern and input is UTF-8; matches begin/end at codepoint
        // boundaries, so replacement cannot split a UTF-8 scalar.
        String::from_utf8(bytes)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid redacted UTF-8"))
    }

    pub fn has_identifiers(&self) -> bool {
        !self.identifiers.is_empty()
    }

    pub fn schema_identifier(&self, input: &str) -> String {
        if self.identifiers.contains(input)
            || self
                .patterns
                .iter()
                .any(|p| input.as_bytes().windows(p.len()).any(|w| w == p))
        {
            format!(
                "redacted-device-{}",
                &arkdeck_contract::sha256_hex(input.as_bytes())[..24]
            )
        } else {
            input.to_owned()
        }
    }

    #[cfg(target_os = "macos")]
    pub fn relative_path(&self, input: &str) -> io::Result<String> {
        if !crate::session_manifest::relative_path(input) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid export Artifact path",
            ));
        }
        let output = input
            .split('/')
            .map(|part| self.schema_identifier(part))
            .collect::<Vec<_>>()
            .join("/");
        if !crate::session_manifest::relative_path(&output) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid redacted Artifact path",
            ));
        }
        Ok(output)
    }

    fn replace(&self, input: &[u8], replacement: &[u8], limit: usize) -> io::Result<Vec<u8>> {
        let mut output = Vec::with_capacity(input.len().min(limit));
        let mut index = 0;
        while index < input.len() {
            if let Some(pattern) = self.patterns.iter().find(|p| input[index..].starts_with(p)) {
                if replacement.len() > limit.saturating_sub(output.len()) {
                    return Err(limit_error());
                }
                output.extend_from_slice(replacement);
                index += pattern.len();
            } else {
                if output.len() == limit {
                    return Err(limit_error());
                }
                output.push(input[index]);
                index += 1;
            }
        }
        Ok(output)
    }
}
fn limit_error() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "redacted Artifact exceeds 64 MiB",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn redactor(values: &[&str]) -> SessionExportRedactor {
        SessionExportRedactor::new(values.iter().map(|s| (*s).to_owned()).collect())
    }
    #[test]
    fn binary_longest_match_and_inserted_text_are_preserved() {
        let redactor = redactor(&["dev1", "dev123", "REDACTED"]);
        let source = b"\xffdev123\0dev1REDACTED\xfe";
        let result = redactor.artifact_bytes(source).unwrap();
        assert_eq!(
            result,
            b"\xff[REDACTED-DEVICE-ID]\0[REDACTED-DEVICE-ID][REDACTED-DEVICE-ID]\xfe"
        );
        assert_eq!(source, b"\xffdev123\0dev1REDACTED\xfe");
    }
    #[test]
    fn short_exact_manifest_identity_differs_from_substring_scrubbing() {
        let redactor = redactor(&["abc", "设备", "abcd"]);
        assert_eq!(
            redactor.manifest_string("abc").unwrap(),
            "[REDACTED-DEVICE-ID]"
        );
        assert_eq!(
            redactor.manifest_string("prefix-abc-设备-abcd").unwrap(),
            "prefix-abc-[R]-[R]"
        );
        assert_eq!(
            redactor.artifact_bytes("abc设备".as_bytes()).unwrap(),
            b"abc[REDACTED-DEVICE-ID]"
        );
        assert_eq!(redactor.artifact_bytes(b"").unwrap(), b"");
    }
    #[test]
    fn expansion_boundary_refuses_whole_output_and_input_is_bounded() {
        let redactor = redactor(&["dev1"]);
        assert_eq!(
            redactor.replace(b"dev1", SENTINEL, SENTINEL.len()).unwrap(),
            SENTINEL
        );
        assert!(
            redactor
                .replace(b"dev1x", SENTINEL, SENTINEL.len())
                .is_err()
        );
        assert!(
            redactor
                .replace(b"dev1", SENTINEL, SENTINEL.len() - 1)
                .is_err()
        );
        assert!(redactor.artifact_bytes(&vec![0; LIMIT + 1]).is_err());
    }
}
