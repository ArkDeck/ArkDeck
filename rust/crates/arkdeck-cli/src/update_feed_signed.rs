//! Pure signed-feed codec. Trust is supplied explicitly for fixture testing;
//! the CLI always uses the pinned production key and exposes no key override.
use arkdeck_contract::{decode_import_chunk, encode_import_chunk};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};

pub const PRODUCTION_PUBLIC_KEY: [u8; 32] = [
    115, 145, 232, 211, 25, 22, 21, 13, 206, 191, 56, 241, 247, 199, 80, 132, 93, 231, 230, 204,
    173, 38, 55, 223, 168, 61, 218, 249, 251, 96, 63, 199,
];
const MAXIMUM_FEED_BYTES: usize = 128 * 1024;

/// Swift UpdateFeedError case names, kept verbatim at the CLI boundary.
pub type Error = &'static str;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Artifact {
    pub url: String,
    pub byte_length: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Payload {
    pub sequence: u64,
    pub version: String,
    pub minimum_system_version: String,
    pub architectures: Vec<String>,
    pub issued_at: String,
    pub expires_at: String,
    pub artifact: Artifact,
    pub release_notes_summary: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Envelope {
    schema_version: u64,
    key_id: String,
    payload: String,
    signature: String,
}

pub(super) fn canonical(value: &impl Serialize) -> Result<Vec<u8>, Error> {
    let value = serde_json::to_value(value).map_err(|_| "invalidPayload")?;
    // These closed typed documents have ASCII field names and only UInt64
    // integers. Value's sorted map plus serde's string escaping matches
    // JSONEncoder.sortedKeys/withoutEscapingSlashes and preserves all 64 bits.
    // The CLI canonical-json/1 helper instead imposes a 53-bit integer limit.
    serde_json::to_vec(&value).map_err(|_| "invalidPayload")
}

fn base64(bytes: &[u8]) -> Result<String, Error> {
    if bytes.is_empty() {
        return Ok(String::new());
    }
    encode_import_chunk(bytes).map_err(|_| "malformedBase64")
}

fn unbase64(value: &str) -> Result<Vec<u8>, Error> {
    if value.is_empty() {
        return Ok(Vec::new());
    }
    if !value.len().is_multiple_of(4) {
        return Err("malformedBase64");
    }
    let padding = value.bytes().rev().take_while(|byte| *byte == b'=').count();
    if padding > 2 {
        return Err("malformedBase64");
    }
    let length = value.len() / 4 * 3 - padding;
    let bytes = decode_import_chunk(value, length as u64).map_err(|_| "malformedBase64")?;
    if base64(&bytes)? != value {
        return Err("malformedBase64");
    }
    Ok(bytes)
}

pub fn signature_input(payload: &[u8], key_id: &str) -> Result<Vec<u8>, Error> {
    if payload.len() > super::MAXIMUM_PAYLOAD_BYTES {
        return Err("invalidPayload");
    }
    let mut input = b"ArkDeck.UpdateFeed.v1\0".to_vec();
    input.extend_from_slice(key_id.as_bytes());
    input.push(0);
    input.extend_from_slice(payload);
    Ok(input)
}

pub fn assemble(payload: &[u8], signature: &[u8], key_id: &str) -> Result<Vec<u8>, Error> {
    // Swift deliberately uses invalidSignature for either size failure here.
    if payload.len() > super::MAXIMUM_PAYLOAD_BYTES || signature.len() != 64 {
        return Err("invalidSignature");
    }
    let envelope = canonical(&Envelope {
        schema_version: 1,
        key_id: key_id.into(),
        payload: base64(payload)?,
        signature: base64(signature)?,
    })?;
    if envelope.len() > MAXIMUM_FEED_BYTES {
        return Err("feedTooLarge");
    }
    Ok(envelope)
}

pub fn decode_and_verify(
    bytes: &[u8],
    key_id: &str,
    public_key: &[u8; 32],
) -> Result<(Payload, Vec<u8>), Error> {
    if bytes.len() > MAXIMUM_FEED_BYTES {
        return Err("feedTooLarge");
    }
    let envelope: Envelope = serde_json::from_slice(bytes).map_err(|_| "malformedEnvelope")?;
    if canonical(&envelope)? != bytes {
        return Err("nonCanonicalEnvelope");
    }
    if envelope.schema_version != 1 {
        return Err("wrongSchemaVersion");
    }
    if envelope.key_id != key_id {
        return Err("unknownKey");
    }
    let payload = unbase64(&envelope.payload)?;
    let signature = unbase64(&envelope.signature)?;
    if payload.len() > super::MAXIMUM_PAYLOAD_BYTES {
        return Err("payloadTooLarge");
    }
    let signature = Signature::from_slice(&signature).map_err(|_| "invalidSignature")?;
    let key = VerifyingKey::from_bytes(public_key).map_err(|_| "unknownKey")?;
    key.verify_strict(&signature_input(&payload, key_id)?, &signature)
        .map_err(|_| "invalidSignature")?;
    let decoded: Payload = serde_json::from_slice(&payload).map_err(|_| "invalidPayload")?;
    if canonical(&decoded)? != payload {
        return Err("nonCanonicalPayload");
    }
    Ok((decoded, payload))
}

/// Static and clock checks shared by assembling and the consumer verifier.
/// Replay admission belongs to the durable consumer owner, never the codec.
pub fn validate_at(payload: &Payload, now: i64) -> Result<(), Error> {
    if payload.sequence == 0 {
        return Err("invalidPayload");
    }
    super::semantic_version(&payload.version).ok_or("invalidVersion")?;
    super::semantic_version(&super::normalized_system(&payload.minimum_system_version))
        .filter(|version| *version >= (14, 0, 0))
        .ok_or("invalidSystemVersion")?;
    if payload.architectures != ["arm64"] {
        return Err("invalidArchitecture");
    }
    super::validate(
        &payload.version,
        &payload.minimum_system_version,
        &payload.release_notes_summary,
        &payload.issued_at,
        &payload.expires_at,
        payload.artifact.byte_length,
        &payload.artifact.sha256,
        &payload.artifact.url,
    )
    .map_err(|error| error.name())?;
    let issued = super::canonical_timestamp(&payload.issued_at).ok_or("invalidTimestamp")?;
    let expires = super::canonical_timestamp(&payload.expires_at).ok_or("invalidTimestamp")?;
    if now < issued {
        return Err("feedNotYetValid");
    }
    if now >= expires {
        return Err("feedExpired");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use arkdeck_contract::canonical_json;
    use ed25519_dalek::{Signer, SigningKey};

    fn payload() -> Payload {
        Payload {
            sequence: 1,
            version: "1.2.3".into(),
            minimum_system_version: "14.0".into(),
            architectures: vec!["arm64".into()],
            issued_at: "2026-09-26T00:00:00Z".into(),
            expires_at: "2026-09-27T00:00:00Z".into(),
            release_notes_summary: "测试 release".into(),
            artifact: Artifact {
                url: "https://github.com/ArkDeck/ArkDeck/releases/download/v1/a.dmg".into(),
                byte_length: 1,
                sha256: "ab".repeat(32),
            },
        }
    }

    fn sign(bytes: &[u8]) -> (Vec<u8>, [u8; 32]) {
        let key = SigningKey::from_bytes(&[42; 32]);
        let signature = key.sign(&signature_input(bytes, "fixture-key").unwrap());
        (
            assemble(bytes, &signature.to_bytes(), "fixture-key").unwrap(),
            key.verifying_key().to_bytes(),
        )
    }

    #[test]
    fn signed_payload_round_trips_and_tampering_or_wrong_domain_fails() {
        let bytes = canonical(&payload()).unwrap();
        let (envelope, key) = sign(&bytes);
        assert_eq!(
            decode_and_verify(&envelope, "fixture-key", &key).unwrap(),
            (payload(), bytes.clone())
        );
        assert_eq!(
            decode_and_verify(&envelope, "other-key", &key),
            Err("unknownKey")
        );
        let other = SigningKey::from_bytes(&[43; 32]).verifying_key().to_bytes();
        assert_eq!(
            decode_and_verify(&envelope, "fixture-key", &other),
            Err("invalidSignature")
        );
        let mut changed: serde_json::Value = serde_json::from_slice(&envelope).unwrap();
        changed["payload"] = serde_json::json!(base64(b"tampered").unwrap());
        assert_eq!(
            decode_and_verify(&canonical_json(&changed).unwrap(), "fixture-key", &key),
            Err("invalidSignature")
        );
        let raw_signature = SigningKey::from_bytes(&[42; 32]).sign(&bytes);
        let wrong_domain = assemble(&bytes, &raw_signature.to_bytes(), "fixture-key").unwrap();
        assert_eq!(
            decode_and_verify(&wrong_domain, "fixture-key", &key),
            Err("invalidSignature")
        );
    }

    #[test]
    fn signature_does_not_authorize_noncanonical_or_untyped_payloads() {
        let mut bytes = canonical(&payload()).unwrap();
        bytes.push(b'\n');
        let (envelope, key) = sign(&bytes);
        assert_eq!(
            decode_and_verify(&envelope, "fixture-key", &key),
            Err("nonCanonicalPayload")
        );
        let (envelope, key) = sign(b"{}");
        assert_eq!(
            decode_and_verify(&envelope, "fixture-key", &key),
            Err("invalidPayload")
        );
        let mut value = serde_json::to_value(payload()).unwrap();
        value["unknown"] = serde_json::json!(true);
        let (envelope, key) = sign(&canonical_json(&value).unwrap());
        assert_eq!(
            decode_and_verify(&envelope, "fixture-key", &key),
            Err("nonCanonicalPayload")
        );
    }

    #[test]
    fn envelope_canonicality_schema_and_base64_are_closed() {
        let (envelope, key) = sign(&canonical(&payload()).unwrap());
        let mut newline = envelope.clone();
        newline.push(b'\n');
        assert_eq!(
            decode_and_verify(&newline, "fixture-key", &key),
            Err("nonCanonicalEnvelope")
        );
        for (field, value, reason) in [
            ("schemaVersion", serde_json::json!(2), "wrongSchemaVersion"),
            ("payload", serde_json::json!("YQ"), "malformedBase64"),
            ("signature", serde_json::json!(""), "invalidSignature"),
        ] {
            let mut changed: serde_json::Value = serde_json::from_slice(&envelope).unwrap();
            changed[field] = value;
            assert_eq!(
                decode_and_verify(&canonical_json(&changed).unwrap(), "fixture-key", &key),
                Err(reason)
            );
        }
        for invalid in ["====", "YQ=", "YR==", "YQ==\n", "💥"] {
            assert!(unbase64(invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn signed_fields_clock_and_size_boundaries_are_enforced() {
        let mut value = payload();
        let issued = super::super::canonical_timestamp(&value.issued_at).unwrap();
        assert_eq!(validate_at(&value, issued), Ok(()));
        assert_eq!(validate_at(&value, issued - 1), Err("feedNotYetValid"));
        assert_eq!(validate_at(&value, issued + 86_400), Err("feedExpired"));
        value.sequence = 0;
        assert_eq!(validate_at(&value, issued), Err("invalidPayload"));
        value.sequence = 1;
        value.architectures.push("x86_64".into());
        assert_eq!(validate_at(&value, issued), Err("invalidArchitecture"));
        assert_eq!(
            assemble(&vec![0; 65_537], &[0; 64], "fixture-key"),
            Err("invalidSignature")
        );
        assert_eq!(
            assemble(b"{}", &[0; 63], "fixture-key"),
            Err("invalidSignature")
        );
        assert_eq!(
            decode_and_verify(
                &vec![0; MAXIMUM_FEED_BYTES + 1],
                "fixture-key",
                &PRODUCTION_PUBLIC_KEY
            ),
            Err("feedTooLarge")
        );
    }

    #[test]
    fn feed_integers_retain_the_full_swift_uint64_domain() {
        for number in [9_007_199_254_740_992, u64::MAX] {
            let mut value = payload();
            value.sequence = number;
            value.artifact.byte_length = number;
            let bytes = canonical(&value).unwrap();
            assert!(String::from_utf8_lossy(&bytes).contains(&number.to_string()));
            let (envelope, key) = sign(&bytes);
            assert_eq!(
                decode_and_verify(&envelope, "fixture-key", &key).unwrap().0,
                value
            );
            let mut envelope: Envelope = serde_json::from_slice(&envelope).unwrap();
            envelope.schema_version = number;
            assert_eq!(
                decode_and_verify(&canonical(&envelope).unwrap(), "fixture-key", &key),
                Err("wrongSchemaVersion")
            );
        }
    }

    #[test]
    fn actual_swift_cryptokit_signatures_and_field_oracle_replay() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/update-feed/signed.json"
        ))
        .unwrap();
        let key: [u8; 32] = unbase64(fixture["publicKeyBase64"].as_str().unwrap())
            .unwrap()
            .try_into()
            .unwrap();
        let key_id = fixture["keyId"].as_str().unwrap();
        let now = super::super::canonical_timestamp(fixture["now"].as_str().unwrap()).unwrap();
        let cases = fixture["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 10);
        for case in cases {
            let envelope = unbase64(case["envelopeBase64"].as_str().unwrap()).unwrap();
            let expected = unbase64(case["payloadBase64"].as_str().unwrap()).unwrap();
            let (payload, bytes) = decode_and_verify(&envelope, key_id, &key).unwrap();
            assert_eq!(bytes, expected, "{}", case["name"]);
            let result = validate_at(&payload, now).err().unwrap_or("valid");
            assert_eq!(result, case["result"], "{}", case["name"]);
        }
    }
}
