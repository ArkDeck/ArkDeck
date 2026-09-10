//! Read-only host-store decoder candidates for TASK-XPA-012 differential work.
//!
//! Document candidates consume bounded bytes; Trace inventory opens a fixed
//! physical cache root read-only. Neither path writes or dispatches.
//! The facade does not use this crate until the complete shadow/cutover gates pass.
//! Filesystem, timestamp and Unicode validation parity remain migration gates;
//! successful decoding here alone is not store admission.

use serde::{Deserialize, Serialize, de::DeserializeOwned};

mod display_names;
pub use display_names::decode_display_names;
mod session;
pub use session::decode_session_configuration;
mod registry;
pub use registry::{decode_bundles, decode_tools};
use serde_json::{Value, json};

#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    Size,
    Shape,
    Header,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct HistoryQuery {
    search: String,
    status: String,
    mode: String,
    #[serde(rename = "sessionID", skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
    #[serde(rename = "targetID", skip_serializing_if = "Option::is_none")]
    target_id: Option<String>,
    #[serde(rename = "timeRange")]
    time_range: String,
    activity: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct HistoryDocument {
    #[serde(rename = "schemaVersion")]
    schema_version: String,
    generation: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    query: Option<HistoryQuery>,
    #[serde(rename = "updatedAtUTC", skip_serializing_if = "Option::is_none")]
    updated_at_utc: Option<String>,
}

// Foundation String equality is canonically equivalent, so comparing a string
// to its NFC spelling does not reject decomposed spellings. Preserve their bytes.
#[cfg(target_os = "macos")]
fn valid_host_text(value: &str, trimmed: bool, allow_tab: bool) -> bool {
    use arkdeck_platform::{host_control_character, host_whitespace_or_newline};
    (!trimmed
        || (value
            .chars()
            .next()
            .is_none_or(|c| !host_whitespace_or_newline(c))
            && value
                .chars()
                .next_back()
                .is_none_or(|c| !host_whitespace_or_newline(c))))
        && value
            .chars()
            .all(|c| !host_control_character(c) || (allow_tab && c == '\t'))
}

// This candidate is a macOS migration. Do not silently substitute another
// platform's Unicode tables for the Foundation owner being compared.
#[cfg(not(target_os = "macos"))]
fn valid_host_text(_: &str, _: bool, _: bool) -> bool {
    false
}

#[cfg(target_os = "macos")]
fn canonical_host_text(value: &str) -> Result<String, DecodeError> {
    arkdeck_platform::host_canonical_text(value).ok_or(DecodeError::Shape)
}
#[cfg(not(target_os = "macos"))]
fn canonical_host_text(_: &str) -> Result<String, DecodeError> {
    Err(DecodeError::Shape)
}

pub struct DecodedStore {
    pub document: Vec<u8>,
    pub projection: Value,
}

fn roundtrip<T: DeserializeOwned + Serialize>(
    bytes: &[u8],
    maximum: usize,
    newline: bool,
) -> Result<(T, Vec<u8>), DecodeError> {
    if bytes.is_empty() || bytes.len() > maximum {
        return Err(DecodeError::Size);
    }
    let doc: T = serde_json::from_slice(bytes).map_err(|_| DecodeError::Shape)?;
    let raw: Value = serde_json::from_slice(bytes).map_err(|_| DecodeError::Shape)?;
    let encoded = serde_json::to_value(&doc).map_err(|_| DecodeError::Shape)?;
    if raw != encoded {
        return Err(DecodeError::Shape);
    }
    let mut document = serde_json::to_vec(&encoded).map_err(|_| DecodeError::Shape)?;
    if newline {
        document.push(b'\n');
    }
    Ok((doc, document))
}

/// Decode the frozen field set, re-encode durable bytes, and derive the list
/// projection. Both outputs are checked against the real Swift owner by the
/// differential harness, not against a second handwritten expected projection.
pub fn decode_history(bytes: &[u8]) -> Result<DecodedStore, DecodeError> {
    let (doc, document) = roundtrip::<HistoryDocument>(bytes, 64 * 1024, true)?;
    if doc.schema_version != "arkdeck.history-filter-store/1"
        || doc.generation == 0
        || doc.generation > i64::MAX as u64
        || (doc.generation == 1 && doc.query.is_some())
        || (doc.updated_at_utc.is_none() != (doc.generation == 1))
    {
        return Err(DecodeError::Header);
    }
    if let Some(q) = &doc.query
        && (q.search.len() > 512
            || ![
                "all",
                "active",
                "needsAttention",
                "succeeded",
                "failed",
                "interrupted",
                "cancelled",
            ]
            .contains(&q.status.as_str())
            || !["all", "execute", "planned", "simulated", "unknown"].contains(&q.mode.as_str())
            || !["anyTime", "lastHour", "lastDay", "lastWeek"].contains(&q.time_range.as_str())
            || ![
                "all",
                "flash",
                "viewer",
                "trace",
                "diagnostics",
                "debug",
                "device",
                "other",
            ]
            .contains(&q.activity.as_str())
            || !valid_host_text(&q.search, false, true)
            || [&q.session_id, &q.target_id]
                .into_iter()
                .flatten()
                .any(|s| s.is_empty() || s.len() > 256 || !valid_host_text(s, true, false)))
    {
        return Err(DecodeError::Shape);
    }
    let query = doc.query.as_ref().map(|q| {
        json!({"search": q.search, "status": q.status, "mode": q.mode,
            "sessionId": q.session_id, "targetId": q.target_id,
            "timeRange": q.time_range, "activity": q.activity})
    });
    let generation = doc.generation.to_string();
    let filters: Vec<Value> = query
        .into_iter()
        .map(|q| {
            json!({
                "schemaVersion": "arkdeck.history-filter/1", "generation": generation,
                "query": q, "updatedAtUtc": doc.updated_at_utc
            })
        })
        .collect();
    Ok(DecodedStore {
        document,
        projection: json!({"schemaVersion": "arkdeck.history-filter-list/1",
            "generation": generation, "filters": filters, "updatedAtUtc": doc.updated_at_utc}),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const EMPTY: &[u8] =
        b"{\"generation\":1,\"schemaVersion\":\"arkdeck.history-filter-store/1\"}\n";

    #[test]
    fn empty_and_tombstone_preserve_generation_without_inventing_optional_keys() {
        let empty = decode_history(EMPTY).unwrap();
        assert_eq!(empty.document, EMPTY);
        assert_eq!(empty.projection["filters"], json!([]));
        let tombstone = b"{\"generation\":9223372036854775807,\"schemaVersion\":\"arkdeck.history-filter-store/1\",\"updatedAtUTC\":\"2026-09-10T01:00:00.000Z\"}\n";
        let decoded = decode_history(tombstone).unwrap();
        assert_eq!(decoded.document, tombstone);
        assert_eq!(decoded.projection["generation"], "9223372036854775807");
    }

    #[test]
    fn refuses_extra_keys_null_keys_duplicate_fields_and_invalid_generations() {
        for bytes in [
            br#"{"generation":1,"schemaVersion":"arkdeck.history-filter-store/1","extra":true}"#.as_slice(),
            br#"{"generation":1,"schemaVersion":"arkdeck.history-filter-store/1","query":null}"#,
            br#"{"generation":1,"generation":2,"schemaVersion":"arkdeck.history-filter-store/1"}"#,
            br#"{"generation":0,"schemaVersion":"arkdeck.history-filter-store/1"}"#,
            br#"{"generation":9223372036854775808,"schemaVersion":"arkdeck.history-filter-store/1"}"#,
            br#"{"generation":2,"schemaVersion":"arkdeck.history-filter-store/1"}"#,
            br#"{"generation":"1","schemaVersion":"arkdeck.history-filter-store/1"}"#,
        ] {
            assert!(decode_history(bytes).is_err());
        }
        assert_eq!(
            decode_history(&vec![b' '; 65537]).err(),
            Some(DecodeError::Size)
        );
    }
}

#[cfg(target_os = "macos")]
mod trace;
#[cfg(target_os = "macos")]
pub use trace::trace_inventory;
