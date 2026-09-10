//! Frozen bootstrap metadata decoders. Content/signature revalidation belongs
//! to the future store owner; these offline projections confer no tool trust.
use crate::{DecodeError, DecodedStore, roundtrip};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Owner {
    kind: String,
    id: String,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BundleRecord {
    reference: String,
    digest: String,
    #[serde(rename = "registeredAtUTC")]
    registered_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    version: Option<String>,
    #[serde(rename = "byteCount")]
    byte_count: i64,
    #[serde(rename = "entryCount")]
    entry_count: i64,
    generation: u64,
    state: String,
    references: Vec<Owner>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BundleIndex {
    #[serde(rename = "schemaVersion")]
    schema_version: String,
    records: Vec<BundleRecord>,
}

pub fn decode_bundles(bytes: &[u8]) -> Result<DecodedStore, DecodeError> {
    let (index, document) = roundtrip::<BundleIndex>(bytes, 4 * 1024 * 1024, false)?;
    if index.schema_version != "arkdeck.bootstrap-bundles/1" || index.records.len() > 128 {
        return Err(DecodeError::Header);
    }
    let projection = Value::Array(
        index
            .records
            .iter()
            .map(|r| {
                json!({
                    "schemaVersion": "arkdeck.runtime-bundle/1", "bundleRef": r.reference,
                    "kind": "daemon-bundle", "platform": "macos",
                    "generation": r.generation.to_string(), "state": r.state,
                    "contentDigest": r.digest, "digestAlgorithm": "sha256-jcs",
                    "contentSchemaVersion": "arkdeck.bundle-content/1",
                    "byteCount": r.byte_count.to_string(), "entryCount": r.entry_count.to_string(),
                    "registeredAtUTC": r.registered_at, "version": r.version,
                    "trust": {"policy": "arkdeck.daemon-helper/1", "signature": "verified",
                        "teamIdentifier": "8AQTYW5FKR", "executionAssessment": "notPerformed"},
                    "references": r.references, "contentRetained": true,
                })
            })
            .collect(),
    );
    Ok(DecodedStore {
        document,
        projection,
    })
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ToolTrust {
    signature: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    identifier: Option<String>,
    #[serde(rename = "teamIdentifier", skip_serializing_if = "Option::is_none")]
    team_identifier: Option<String>,
    #[serde(
        rename = "codeDirectorySHA256",
        skip_serializing_if = "Option::is_none"
    )]
    code_directory_sha256: Option<String>,
}

impl ToolTrust {
    fn projection(&self) -> Value {
        json!({
            "policy": "arkdeck.host-tool-inspection/1", "signature": self.signature,
            "signingIdentifier": self.identifier, "teamIdentifier": self.team_identifier,
            "codeDirectoryIdentitySHA256": self.code_directory_sha256,
            "platformTrust": "unverified", "executionAssessment": "notPerformed",
            "registeredIdentity": false, "profileReferences": [], "toolVersion": null,
            "versionSource": null,
        })
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Dependency {
    name: String,
    sha256: String,
    #[serde(rename = "byteCount")]
    byte_count: i64,
    #[serde(rename = "quarantineSHA256", skip_serializing_if = "Option::is_none")]
    quarantine_sha256: Option<String>,
    trust: ToolTrust,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ToolRecord {
    reference: String,
    #[serde(rename = "contentDigest")]
    content_digest: String,
    #[serde(rename = "executableSHA256")]
    executable_sha256: String,
    #[serde(rename = "registeredAt")]
    registered_at: String,
    #[serde(rename = "byteCount")]
    byte_count: i64,
    #[serde(rename = "quarantineSHA256", skip_serializing_if = "Option::is_none")]
    quarantine_sha256: Option<String>,
    trust: ToolTrust,
    dependencies: Vec<Dependency>,
    relocatable: bool,
    generation: i64,
    state: String,
    references: Vec<Owner>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Selection {
    #[serde(rename = "activeToolRef")]
    active_tool_ref: String,
    #[serde(rename = "activeGeneration")]
    active_generation: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pending: Option<PendingSelection>,
    #[serde(rename = "lastOutcome", skip_serializing_if = "Option::is_none")]
    last_outcome: Option<SelectionOutcome>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct PendingSelection {
    #[serde(rename = "actionID")]
    action_id: String,
    #[serde(rename = "oldToolRef")]
    old_tool_ref: String,
    #[serde(rename = "newToolRef")]
    new_tool_ref: String,
    #[serde(rename = "expectedActiveGeneration")]
    expected_active_generation: u64,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct SelectionOutcome {
    #[serde(rename = "actionID")]
    action_id: String,
    result: String,
    #[serde(rename = "oldToolRef")]
    old_tool_ref: String,
    #[serde(rename = "newToolRef")]
    new_tool_ref: String,
    #[serde(rename = "activeGeneration")]
    active_generation: u64,
    #[serde(rename = "reasonCode", skip_serializing_if = "Option::is_none")]
    reason_code: Option<String>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ToolIndex {
    #[serde(rename = "schemaVersion")]
    schema_version: String,
    records: Vec<ToolRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    selection: Option<Selection>,
}

/// Unregistered-tool projections only. Matching a fresh, published Provider
/// identity is deliberately not inferred from stored metadata.
pub fn decode_tools(bytes: &[u8]) -> Result<DecodedStore, DecodeError> {
    let (index, document) = roundtrip::<ToolIndex>(bytes, 4 * 1024 * 1024, false)?;
    if index.schema_version != "arkdeck.bootstrap-tools/2" || index.records.len() > 128 {
        return Err(DecodeError::Header);
    }
    let projection = Value::Array(
        index
            .records
            .iter()
            .map(|r| {
                let generation = index
                    .selection
                    .as_ref()
                    .filter(|s| s.active_tool_ref == r.reference)
                    .map(|s| s.active_generation.to_string());
                let dependencies: Vec<_> = r.dependencies.iter().map(|d| json!({
            "name": d.name, "sha256": d.sha256, "byteCount": d.byte_count.to_string(),
            "quarantineSHA256": d.quarantine_sha256, "trust": d.trust.projection(),
        })).collect();
                json!({
                    "schemaVersion": "arkdeck.runtime-tool/1", "toolRef": r.reference,
                    "kind": "hdc", "platform": "macos", "source": "registeredCopy",
                    "generation": r.generation.to_string(), "state": r.state,
                    "contentDigest": r.content_digest, "digestAlgorithm": "sha256-jcs",
                    "contentSchemaVersion": "arkdeck.tool-content/1",
                    "executableSHA256": r.executable_sha256, "byteCount": r.byte_count.to_string(),
                    "quarantineSHA256": r.quarantine_sha256, "registeredAt": r.registered_at,
                    "trust": r.trust.projection(), "dependencies": dependencies,
                    "dependencyLayout": "hdc-sibling-libusb/1", "relocatable": r.relocatable,
                    "selected": r.references.iter().any(|o| o.kind == "activeSelection"),
                    "activeSelectionGeneration": generation, "references": r.references,
                    "contentRetained": true,
                })
            })
            .collect(),
    );
    Ok(DecodedStore {
        document,
        projection,
    })
}
