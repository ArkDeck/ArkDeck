use crate::{DecodeError, DecodedStore, canonical_host_text, roundtrip, valid_host_text};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashSet;

fn valid_name(value: &str) -> bool {
    (1..=256).contains(&value.len()) && valid_host_text(value, true, false)
}

fn target_identifier(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
}

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
    let mut candidate_keys = HashSet::new();
    let candidate_spellings = candidates
        .iter()
        .map(|r| canonical_host_text(&r.candidate))
        .collect::<Result<Vec<_>, _>>()?;
    for r in candidates {
        if !candidate_keys.insert(canonical_host_text(&format!(
            "{}\n{}",
            r.candidate, r.observation_id
        ))?) {
            return Err(DecodeError::Shape);
        }
    }
    if doc.schema_version != "arkdeck.target-display-names/1"
        || doc.records.len() > 4096
        || candidates.len() > 4096
        || doc
            .records
            .iter()
            .any(|r| !(2..=i64::MAX as u64).contains(&r.generation))
        || doc.records.iter().any(|r| {
            !target_identifier(&r.target_id)
                || r.name.as_ref().is_some_and(|n| !valid_name(n))
                || !crate::format_time::valid_format_timestamp(&r.updated_at)
        })
        || candidates.iter().any(|r| {
            !valid_name(&r.name)
                || !crate::format_time::valid_format_timestamp(&r.updated_at)
                || !(1..=1024).contains(&r.candidate.len())
                || !(1..=128).contains(&r.observation_id.len())
        })
        || candidates
            .iter()
            .any(|r| !(2..=i64::MAX as u64).contains(&r.generation))
    {
        return Err(DecodeError::Header);
    }
    // Swift persists these indexes in UTF-8 order and rejects duplicates.
    if doc
        .records
        .windows(2)
        .any(|r| r[0].target_id >= r[1].target_id)
        || candidates.windows(2).enumerate().any(|(i, r)| {
            if candidate_spellings[i] == candidate_spellings[i + 1] {
                r[0].observation_id >= r[1].observation_id
            } else {
                r[0].candidate >= r[1].candidate
            }
        })
        || candidates.iter().any(
            |r| match (&r.staged_target_id, r.staged_target_generation) {
                (None, None) => false,
                (Some(id), Some(generation)) => !doc.records.iter().any(|target| {
                    target.target_id == *id
                        && target.generation == generation
                        && target.name.as_deref().is_some_and(|name| {
                            matches!((canonical_host_text(name), canonical_host_text(&r.name)),
                                (Ok(a), Ok(b)) if a == b)
                        })
                }),
                _ => true,
            },
        )
    {
        return Err(DecodeError::Shape);
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
