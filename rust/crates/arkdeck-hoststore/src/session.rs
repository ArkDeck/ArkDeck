//! The frozen Session configuration document. Inventory/retention measurements
//! are a distinct input to full status and are not invented by this decoder.
use crate::{DecodeError, DecodedStore, roundtrip};
use serde::{Deserialize, Serialize};
use serde_json::json;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Policy {
    total_quota_bytes: u64,
    safety_margin_bytes: u64,
    retention_days: u64,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Document {
    schema_version: String,
    generation: u64,
    root_kind: String,
    root_path: String,
    policy: Policy,
}

pub fn decode_session_configuration(bytes: &[u8]) -> Result<DecodedStore, DecodeError> {
    let (doc, document) = roundtrip::<Document>(bytes, 64 * 1024, true)?;
    let bounded_positive = |n: u64| (1..=i64::MAX as u64).contains(&n);
    if bytes != document
        || doc.schema_version != "arkdeck.session-storage-store/1"
        || !bounded_positive(doc.generation)
        || !["default", "custom"].contains(&doc.root_kind.as_str())
        || !doc.root_path.starts_with('/')
        || doc.root_path.len() > 4096
        || doc.root_path.contains('\0')
        || !bounded_positive(doc.policy.total_quota_bytes)
        || !bounded_positive(doc.policy.safety_margin_bytes)
        || !bounded_positive(doc.policy.retention_days)
        || doc.policy.total_quota_bytes <= doc.policy.safety_margin_bytes
    {
        return Err(DecodeError::Header);
    }
    // Exactly the configuration fields of RuntimeSessionStorageStatus.projection.
    // No usage numbers are copied from a Swift result or assumed to be zero.
    let projection = json!({
        "generation": doc.generation.to_string(), "rootPath": doc.root_path,
        "rootKind": doc.root_kind,
        "policy": {"totalQuotaBytes": doc.policy.total_quota_bytes.to_string(),
            "safetyMarginBytes": doc.policy.safety_margin_bytes.to_string(),
            "retentionDays": doc.policy.retention_days.to_string()},
    });
    Ok(DecodedStore {
        document,
        projection,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn bytes(quota: u64, margin: u64, days: u64) -> Vec<u8> {
        let value = json!({"schemaVersion": "arkdeck.session-storage-store/1",
            "generation": 2, "rootKind": "custom", "rootPath": "/fixture/sessions",
            "policy": {"totalQuotaBytes": quota, "safetyMarginBytes": margin, "retentionDays": days}});
        let mut bytes = serde_json::to_vec(&value).unwrap();
        bytes.push(b'\n');
        bytes
    }
    #[test]
    fn preserves_full_width_quota_and_refuses_out_of_bounds_policy() {
        let result = decode_session_configuration(&bytes(i64::MAX as u64, 1, 90)).unwrap();
        assert_eq!(
            result.projection["policy"]["totalQuotaBytes"],
            "9223372036854775807"
        );
        for (quota, margin, days) in [
            (10, 10, 1),
            (10, 11, 1),
            (10, 0, 1),
            (10, 1, 0),
            (u64::MAX, 1, 1),
        ] {
            assert!(decode_session_configuration(&bytes(quota, margin, days)).is_err());
        }
        let mut noncanonical = bytes(10, 1, 1);
        noncanonical.insert(0, b' ');
        assert!(decode_session_configuration(&noncanonical).is_err());
    }
}
