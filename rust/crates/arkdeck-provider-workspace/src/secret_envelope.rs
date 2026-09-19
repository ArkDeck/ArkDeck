//! Swift `OpenHarmonySigningSecretEnvelope`: the Keychain value that carries
//! both signing passwords, `{"schemaVersion":
//! "arkdeck-openharmony-signing-secret/v1", "keystorePassword": <base64>,
//! "keyPassword": <base64>}` as Foundation's default `JSONEncoder` writes it
//! (member order unspecified, the solidus escaped). The reader takes any
//! member order and escaping, refuses any other member, and wipes every
//! intermediate copy it owns.
use crate::SigningError;
use arkdeck_platform::{Secret, wipe};
use serde::Deserialize;

pub const SECRET_ENVELOPE_SCHEMA: &str = "arkdeck-openharmony-signing-secret/v1";
const MAX_ENVELOPE_BYTES: usize = 64 * 1024;

/// Both passwords of one preset.
pub struct SecretPair {
    pub keystore: Secret,
    pub key: Secret,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Wire {
    #[serde(rename = "schemaVersion")]
    schema_version: String,
    #[serde(rename = "keystorePassword")]
    keystore_password: String,
    #[serde(rename = "keyPassword")]
    key_password: String,
}

impl Drop for Wire {
    fn drop(&mut self) {
        for text in [&mut self.keystore_password, &mut self.key_password] {
            let mut bytes = std::mem::take(text).into_bytes();
            wipe(&mut bytes);
        }
    }
}

/// Swift `decodeEnvelope(_:)`.
pub fn decode_envelope(bytes: &[u8]) -> Result<SecretPair, SigningError> {
    let invalid = || SigningError::secret("signing Keychain envelope is invalid");
    if bytes.len() > MAX_ENVELOPE_BYTES {
        return Err(invalid());
    }
    let wire: Wire = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    let keystore = crate::base64::decode(wire.keystore_password.as_bytes()).ok_or_else(invalid)?;
    let key = crate::base64::decode(wire.key_password.as_bytes()).ok_or_else(invalid)?;
    if wire.schema_version != SECRET_ENVELOPE_SCHEMA {
        return Err(SigningError::secret(
            "signing Keychain envelope schema is unsupported",
        ));
    }
    Ok(SecretPair { keystore, key })
}

/// Swift `encodeEnvelope(keystorePassword:keyPassword:)`, in Foundation's
/// default spelling with the members in declaration order. Swift's reader
/// accepts any member order, so the Keychain value need not be byte-equal to
/// a Swift-written one.
pub fn encode_envelope(keystore: &[u8], key: &[u8]) -> Secret {
    let mut keystore = crate::base64::encode(keystore);
    let mut key = crate::base64::encode(key);
    let text = format!(
        "{{\"schemaVersion\":\"{}\",\"keystorePassword\":\"{}\",\"keyPassword\":\"{}\"}}",
        SECRET_ENVELOPE_SCHEMA.replace('/', "\\/"),
        keystore.replace('/', "\\/"),
        key.replace('/', "\\/"),
    );
    for text in [&mut keystore, &mut key] {
        let mut bytes = std::mem::take(text).into_bytes();
        wipe(&mut bytes);
    }
    Secret::new(text.into_bytes())
}

/// Swift `validateSecret(_:)`: non-empty, at most 4 096 bytes, and no NUL,
/// line feed or carriage return, since a password is answered as one line.
pub fn validate_secret(secret: &[u8]) -> Result<(), SigningError> {
    if secret.is_empty()
        || secret.len() > 4_096
        || secret.iter().any(|byte| matches!(byte, 0 | b'\n' | b'\r'))
    {
        return Err(SigningError::invalid("password is empty or unbounded"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{decode_envelope, encode_envelope, validate_secret};
    use crate::SigningError;

    /// Printed by Swift `JSONEncoder().encode(OpenHarmonySigningSecretEnvelope(…))`
    /// for these fixture bytes: members in hash order, the solidus escaped.
    const SWIFT_WRITTEN: &str = r#"{"keyPassword":"a2V5LWZpeHR1cmU=","schemaVersion":"arkdeck-openharmony-signing-secret\/v1","keystorePassword":"\/++\/Pj8="}"#;

    #[test]
    fn reads_the_envelope_swift_writes() {
        let pair = decode_envelope(SWIFT_WRITTEN.as_bytes()).unwrap();
        assert_eq!(pair.keystore.as_bytes(), [0xff, 0xef, 0xbf, 0x3e, 0x3f]);
        assert_eq!(pair.key.as_bytes(), b"key-fixture");
    }

    #[test]
    fn its_own_spelling_reads_back() {
        let encoded = encode_envelope(b"keystore/+secret", b"key-secret");
        let pair = decode_envelope(encoded.as_bytes()).unwrap();
        assert_eq!(pair.keystore.as_bytes(), b"keystore/+secret");
        assert_eq!(pair.key.as_bytes(), b"key-secret");
    }

    /// One member more than Swift's `CodingKeys` is refused, not narrowed.
    #[test]
    fn one_more_member_is_refused() {
        let extra = r#"{"schemaVersion":"arkdeck-openharmony-signing-secret/v1","keystorePassword":"YQ==","keyPassword":"Yg==","note":"x"}"#;
        assert_eq!(
            decode_envelope(extra.as_bytes()).err(),
            Some(SigningError::secret("signing Keychain envelope is invalid"))
        );
    }

    #[test]
    fn a_wrong_schema_missing_member_or_bad_base64_is_refused() {
        let schema = r#"{"schemaVersion":"arkdeck-openharmony-signing-secret/v2","keystorePassword":"YQ==","keyPassword":"Yg=="}"#;
        assert_eq!(
            decode_envelope(schema.as_bytes()).err(),
            Some(SigningError::secret(
                "signing Keychain envelope schema is unsupported"
            ))
        );
        for invalid in [
            r#"{"schemaVersion":"arkdeck-openharmony-signing-secret/v1","keystorePassword":"YQ=="}"#,
            r#"{"schemaVersion":"arkdeck-openharmony-signing-secret/v1","keystorePassword":"YQ","keyPassword":"Yg=="}"#,
            r#"not json"#,
        ] {
            assert_eq!(
                decode_envelope(invalid.as_bytes()).err(),
                Some(SigningError::secret("signing Keychain envelope is invalid")),
                "{invalid}"
            );
        }
    }

    #[test]
    fn a_password_is_one_bounded_line() {
        assert!(validate_secret(b"123456").is_ok());
        for bad in [&b""[..], b"a\nb", b"a\rb", b"a\0b", &[b'a'; 4097][..]] {
            assert!(validate_secret(bad).is_err());
        }
    }
}
