use crate::{DecodeError, DecodedStore, roundtrip};
use serde::{Deserialize, Serialize};
use serde_json::json;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Record {
    #[serde(rename = "targetID")]
    target_id: String,
    generation: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(rename = "updatedAtUTC")]
    updated_at: String,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Candidate {
    candidate: String,
    #[serde(rename = "observationID")]
    observation_id: String,
    generation: u64,
    name: String,
    #[serde(rename = "updatedAtUTC")]
    updated_at: String,
    #[serde(rename = "stagedTargetID", skip_serializing_if = "Option::is_none")]
    staged_target_id: Option<String>,
    #[serde(
        rename = "stagedTargetGeneration",
        skip_serializing_if = "Option::is_none"
    )]
    staged_target_generation: Option<u64>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Document {
    #[serde(rename = "schemaVersion")]
    schema_version: String,
    records: Vec<Record>,
    #[serde(rename = "candidateRecords", skip_serializing_if = "Option::is_none")]
    candidates: Option<Vec<Candidate>>,
}

/// Projects each persisted target/candidate at its persisted generation. Stale
/// observation requests and missing-target defaults need separate query inputs;
/// this snapshot decoder does not assert those query semantics are migrated.
pub fn decode_display_names(bytes: &[u8]) -> Result<DecodedStore, DecodeError> {
    let (doc, document) = roundtrip::<Document>(bytes, 512 * 1024, true)?;
    let candidates = doc.candidates.as_deref().unwrap_or_default();
    if doc.schema_version != "arkdeck.target-display-names/1"
        || doc.records.len() > 4096
        || candidates.len() > 4096
        || doc
            .records
            .iter()
            .any(|r| !(2..=i64::MAX as u64).contains(&r.generation))
        || candidates
            .iter()
            .any(|r| !(2..=i64::MAX as u64).contains(&r.generation))
    {
        return Err(DecodeError::Header);
    }
    let targets: Vec<_> = doc.records.iter().map(|r| json!({
        "schemaVersion": "arkdeck.target-display-name/1", "targetId": r.target_id,
        "generation": r.generation.to_string(), "name": r.name, "updatedAtUtc": r.updated_at,
    })).collect();
    let candidates: Vec<_> = candidates
        .iter()
        .map(|r| {
            json!({
                "schemaVersion": "arkdeck.candidate-display-name/1", "candidateKey": r.candidate,
                "observationId": r.observation_id, "generation": r.generation.to_string(),
                "name": r.name, "updatedAtUtc": r.updated_at,
            })
        })
        .collect();
    Ok(DecodedStore {
        document,
        projection: json!({"targets": targets, "candidates": candidates}),
    })
}
