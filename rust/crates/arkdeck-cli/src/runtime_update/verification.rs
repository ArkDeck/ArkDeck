use super::{Feed, NoUpdate, ReplayDecision, ReplayRecord, ReplayStore, State};
use crate::update_feed::{PRODUCTION_KEY_ID, normalized_system, semantic_version, signed};

pub struct ProductIdentity {
    pub app_version: String,
    pub system_version: String,
    pub architecture: String,
}

pub fn verify_feed(
    bytes: &[u8],
    identity: &ProductIdentity,
    now: i64,
    replay: &ReplayStore,
) -> Result<State, &'static str> {
    verify_with_key(
        bytes,
        identity,
        now,
        replay,
        PRODUCTION_KEY_ID,
        &signed::PRODUCTION_PUBLIC_KEY,
    )
}

fn verify_with_key(
    bytes: &[u8],
    identity: &ProductIdentity,
    now: i64,
    replay: &ReplayStore,
    key_id: &str,
    public_key: &[u8; 32],
) -> Result<State, &'static str> {
    // Preserve Swift's order: malformed local versions fail before signature
    // processing; authenticity/static/freshness/downgrade checks precede any
    // durable watermark write. Applicability is decided after admission.
    let installed = semantic_version(&identity.app_version).ok_or("invalidVersion")?;
    let system = semantic_version(&normalized_system(&identity.system_version))
        .ok_or("invalidSystemVersion")?;
    let (payload, canonical) = signed::decode_and_verify(bytes, key_id, public_key)?;
    signed::validate_at(&payload, now)?;
    let candidate = semantic_version(&payload.version).ok_or("invalidVersion")?;
    if candidate < installed {
        return Err("downgrade");
    }
    let digest = arkdeck_contract::sha256_hex(&canonical);
    match replay.admit(&ReplayRecord {
        sequence: payload.sequence,
        payload_sha256: digest.clone(),
        version: payload.version.clone(),
    })? {
        ReplayDecision::Accepted => {}
        ReplayDecision::Replay => return Err("replay"),
        ReplayDecision::SequenceConflict => return Err("sequenceConflict"),
        ReplayDecision::NonIncreasingRelease => return Err("nonIncreasingRelease"),
    }
    if candidate == installed {
        return Ok(State::NoUpdate {
            reason: NoUpdate::CurrentVersion,
        });
    }
    if !payload.architectures.contains(&identity.architecture) {
        return Ok(State::NoUpdate {
            reason: NoUpdate::UnsupportedArchitecture,
        });
    }
    let minimum = semantic_version(&normalized_system(&payload.minimum_system_version))
        .ok_or("invalidSystemVersion")?;
    if minimum > system {
        return Ok(State::NoUpdate {
            reason: NoUpdate::UnsupportedSystem,
        });
    }
    Ok(State::Available {
        feed: Feed {
            payload,
            canonical_payload: arkdeck_contract::encode_import_chunk(&canonical)
                .map_err(|_| "invalidPayload")?,
            payload_sha256: digest,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    struct Root(PathBuf);
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn fixture() -> (Vec<u8>, [u8; 32], i64) {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/update-feed/signed.json"
        ))
        .unwrap();
        fn decode(text: &str) -> Vec<u8> {
            let padding = text.bytes().rev().take_while(|b| *b == b'=').count();
            arkdeck_contract::decode_import_chunk(text, (text.len() / 4 * 3 - padding) as u64)
                .unwrap()
        }
        let bytes = decode(fixture["cases"][0]["envelopeBase64"].as_str().unwrap());
        let key = decode(fixture["publicKeyBase64"].as_str().unwrap())
            .try_into()
            .unwrap();
        let now =
            crate::update_feed::canonical_timestamp(fixture["now"].as_str().unwrap()).unwrap();
        (bytes, key, now)
    }

    #[test]
    fn valid_but_inapplicable_feed_still_advances_watermark_while_refusals_do_not() {
        let (bytes, key, now) = fixture();
        for (app, system, arch, expected) in [
            ("1.0.0", "14.0", "arm64", "available"),
            ("1.2.3", "14.0", "arm64", "currentVersion"),
            ("1.0.0", "14.0", "x86_64", "unsupportedArchitecture"),
            ("1.0.0", "13.0", "arm64", "unsupportedSystem"),
            ("2.0.0", "14.0", "arm64", "downgrade"),
            ("bad", "14.0", "arm64", "invalidVersion"),
            ("1.0.0", "bad", "arm64", "invalidSystemVersion"),
        ] {
            let root = Root(
                std::env::temp_dir()
                    .join(format!("arkdeck-feed-verify-{}", crate::client_frame_id())),
            );
            let replay = ReplayStore::new(&root.0);
            let identity = ProductIdentity {
                app_version: app.into(),
                system_version: system.into(),
                architecture: arch.into(),
            };
            let result = verify_with_key(&bytes, &identity, now, &replay, "fixture-key", &key);
            let got = match &result {
                Ok(State::Available { .. }) => "available",
                Ok(State::NoUpdate {
                    reason: NoUpdate::CurrentVersion,
                }) => "currentVersion",
                Ok(State::NoUpdate {
                    reason: NoUpdate::UnsupportedArchitecture,
                }) => "unsupportedArchitecture",
                Ok(State::NoUpdate {
                    reason: NoUpdate::UnsupportedSystem,
                }) => "unsupportedSystem",
                Err(error) => error,
                other => panic!("unexpected state {other:?}"),
            };
            assert_eq!(got, expected);
            assert_eq!(replay.load().unwrap().is_some(), result.is_ok());
        }
    }

    #[test]
    fn production_trust_and_expiration_refuse_without_watermark_mutation() {
        let (bytes, key, now) = fixture();
        let root = Root(
            std::env::temp_dir().join(format!("arkdeck-feed-refuse-{}", crate::client_frame_id())),
        );
        let replay = ReplayStore::new(&root.0);
        let identity = ProductIdentity {
            app_version: "1.0.0".into(),
            system_version: "14.0".into(),
            architecture: "arm64".into(),
        };
        assert_eq!(
            verify_feed(&bytes, &identity, now, &replay),
            Err("unknownKey")
        );
        assert_eq!(
            verify_with_key(
                &bytes,
                &identity,
                now + 31 * 86400,
                &replay,
                "fixture-key",
                &key
            ),
            Err("feedExpired")
        );
        assert!(!root.0.exists());
    }
}
