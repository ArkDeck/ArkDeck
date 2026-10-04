//! Frozen bootstrap metadata decoders. Content/signature revalidation belongs
//! to the future store owner; these offline projections confer no tool trust.
use crate::{DecodeError, DecodedStore, roundtrip};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

fn digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub(crate) fn identifier(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}
fn timestamp(value: &str) -> bool {
    value.len() <= 32 && arkdeck_platform::host_legacy_iso8601(value) == Some(true)
}
fn owners(values: &[Owner]) -> bool {
    let mut seen = std::collections::BTreeSet::new();
    values.len() <= 1024
        && values.iter().all(|owner| {
            [
                "installation",
                "rollback",
                "controlAction",
                "job",
                "recovery",
                "agentExecution",
                "activeLease",
                "activeSelection",
                "workspacePreset",
            ]
            .contains(&owner.kind.as_str())
                && identifier(&owner.id)
                && seen.insert((&owner.kind, &owner.id))
        })
}
fn state(value: &str, generation: u64, references: &[Owner]) -> bool {
    owners(references)
        && ((value == "available" && generation == 1)
            || (value == "removed" && generation == 2 && references.is_empty()))
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Owner {
    pub(crate) kind: String,
    pub(crate) id: String,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct BundleRecord {
    pub(crate) reference: String,
    pub(crate) digest: String,
    #[serde(rename = "registeredAtUTC")]
    registered_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    version: Option<String>,
    #[serde(rename = "byteCount")]
    byte_count: i64,
    #[serde(rename = "entryCount")]
    entry_count: i64,
    pub(crate) generation: u64,
    pub(crate) state: String,
    pub(crate) references: Vec<Owner>,
    /// A Windows record's host tag, `"windows"`, and its daemon's signer
    /// name (the leaf's single `O=`, else its `CN=`). A macOS record has
    /// neither, and each host reads only its own form.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) platform: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) signer: Option<String>,
}

/// Whether a bundle record is this host's form: macOS records carry no host
/// tag; a Windows record names `"windows"` and one printable signer name.
fn host_form(record: &BundleRecord) -> bool {
    if cfg!(windows) {
        record.platform.as_deref() == Some("windows")
            && record.signer.as_deref().is_some_and(|signer| {
                !signer.is_empty()
                    && signer.len() <= 256
                    && signer.trim() == signer
                    && !signer.chars().any(char::is_control)
            })
    } else {
        record.platform.is_none() && record.signer.is_none()
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct BundleIndex {
    #[serde(rename = "schemaVersion")]
    schema_version: String,
    pub(crate) records: Vec<BundleRecord>,
}

pub fn decode_bundles(bytes: &[u8]) -> Result<DecodedStore, DecodeError> {
    let (index, document) = read_bundles(bytes)?;
    let projection = Value::Array(
        index
            .records
            .iter()
            .map(|r| {
                let (platform, trust) = match r.signer.as_deref() {
                    // A Windows daemon package: its daemon image's signer,
                    // pinned to the Runtime's own (maintainer ruling 17).
                    Some(signer) => (
                        "windows",
                        json!({"policy": "arkdeck.windows-daemon-package/1", "signature": "verified",
                            "teamIdentifier": signer, "executionAssessment": "notPerformed"}),
                    ),
                    None => (
                        "macos",
                        json!({"policy": "arkdeck.daemon-helper/1", "signature": "verified",
                            "teamIdentifier": "8AQTYW5FKR", "executionAssessment": "notPerformed"}),
                    ),
                };
                json!({
                    "schemaVersion": "arkdeck.runtime-bundle/1", "bundleRef": r.reference,
                    "kind": "daemon-bundle", "platform": platform,
                    "generation": r.generation.to_string(), "state": r.state,
                    "contentDigest": r.digest, "digestAlgorithm": "sha256-jcs",
                    "contentSchemaVersion": "arkdeck.bundle-content/1",
                    "byteCount": r.byte_count.to_string(), "entryCount": r.entry_count.to_string(),
                    "registeredAtUTC": r.registered_at, "version": r.version,
                    "trust": trust,
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

/// Swift `BootstrapBundleRegistry.readIndex`'s bounded schema and record
/// checks over the strictly decoded index, and its re-encoded bytes.
pub(crate) fn read_bundles(bytes: &[u8]) -> Result<(BundleIndex, Vec<u8>), DecodeError> {
    let (index, document) = roundtrip::<BundleIndex>(bytes, 4 * 1024 * 1024, false)?;
    if index.schema_version != "arkdeck.bootstrap-bundles/1"
        || index.records.len() > 128
        || !index
            .records
            .windows(2)
            .all(|pair| pair[0].reference < pair[1].reference)
        || index.records.iter().any(|r| {
            !digest(&r.digest)
                || r.reference != format!("bundle:sha256:{}", r.digest)
                || !(0..=1_073_741_824).contains(&r.byte_count)
                || !(1..=4096).contains(&r.entry_count)
                || !timestamp(&r.registered_at)
                || !r.version.as_deref().is_none_or(|v| {
                    !v.is_empty() && v.len() <= 128 && v.bytes().all(|b| (32..127).contains(&b))
                })
                || !state(&r.state, r.generation, &r.references)
                || !host_form(r)
        })
    {
        return Err(DecodeError::Header);
    }
    Ok((index, document))
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ToolTrust {
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

// Diagnostic lookup of the existing Swift composition's published identities.
// This reproduces HDCRegisteredToolIdentity.match; it neither adds a supported
// operation nor grants trust, selection or dispatch authority. Actual Swift
// lookup parity and source pins cover both published identities.
pub(crate) fn published_identity(sha256: &str) -> Option<Value> {
    let (version, profiles): (&str, &[&str]) = match sha256 {
        "48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260" => {
            ("3.2.0d", &["OPENHARMONY-TOOLS@0.3.0"])
        }
        "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83" => (
            "3.2.0f",
            &["OPENHARMONY-TOOLS@0.5.0", "OPENHARMONY-TOOLS@0.6.0"],
        ),
        _ => return None,
    };
    Some(json!({"version": version, "profileReferences": profiles}))
}

pub fn decode_tool_identity(bytes: &[u8]) -> Result<DecodedStore, DecodeError> {
    if bytes.is_empty() || bytes.len() > 4096 {
        return Err(DecodeError::Size);
    }
    let sha256: String = serde_json::from_slice(bytes).map_err(|_| DecodeError::Shape)?;
    Ok(DecodedStore {
        document: serde_json::to_vec(&sha256).map_err(|_| DecodeError::Shape)?,
        projection: json!({"identity": published_identity(&sha256)}),
    })
}

impl ToolTrust {
    fn well_formed(&self) -> bool {
        ["unsigned", "adHoc", "verified"].contains(&self.signature.as_str())
            && [self.identifier.as_deref(), self.team_identifier.as_deref()]
                .into_iter()
                .flatten()
                .all(|s| {
                    !s.is_empty()
                        && s.len() <= 256
                        && !s.chars().any(|c| c < '\u{20}' || c == '\u{7f}')
                })
            && if self.signature == "unsigned" {
                self.identifier.is_none()
                    && self.team_identifier.is_none()
                    && self.code_directory_sha256.is_none()
            } else {
                self.code_directory_sha256.as_deref().is_none_or(digest)
            }
    }
    fn projection(&self, identity: Option<Value>) -> Value {
        json!({
            "policy": "arkdeck.host-tool-inspection/1", "signature": self.signature,
            "signingIdentifier": self.identifier, "teamIdentifier": self.team_identifier,
            "codeDirectoryIdentitySHA256": self.code_directory_sha256,
            "platformTrust": "unverified", "executionAssessment": "notPerformed",
            "registeredIdentity": identity.is_some(),
            "profileReferences": identity.as_ref().map(|v| v["profileReferences"].clone()).unwrap_or_else(|| json!([])),
            "toolVersion": identity.as_ref().map(|v| v["version"].clone()),
            "versionSource": identity.as_ref().map(|_| "publishedProfileDigestMatch"),
        })
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Dependency {
    name: String,
    sha256: String,
    #[serde(rename = "byteCount")]
    byte_count: i64,
    #[serde(rename = "quarantineSHA256", skip_serializing_if = "Option::is_none")]
    quarantine_sha256: Option<String>,
    trust: ToolTrust,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ToolRecord {
    pub(crate) reference: String,
    #[serde(rename = "contentDigest")]
    pub(crate) content_digest: String,
    #[serde(rename = "executableSHA256")]
    pub(crate) executable_sha256: String,
    #[serde(rename = "registeredAt")]
    pub(crate) registered_at: String,
    #[serde(rename = "byteCount")]
    pub(crate) byte_count: i64,
    #[serde(rename = "quarantineSHA256", skip_serializing_if = "Option::is_none")]
    pub(crate) quarantine_sha256: Option<String>,
    pub(crate) trust: ToolTrust,
    pub(crate) dependencies: Vec<Dependency>,
    pub(crate) relocatable: bool,
    pub(crate) generation: i64,
    pub(crate) state: String,
    pub(crate) references: Vec<Owner>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Selection {
    #[serde(rename = "activeToolRef")]
    pub(crate) active_tool_ref: String,
    #[serde(rename = "activeGeneration")]
    pub(crate) active_generation: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) pending: Option<PendingSelection>,
    #[serde(rename = "lastOutcome", skip_serializing_if = "Option::is_none")]
    pub(crate) last_outcome: Option<SelectionOutcome>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PendingSelection {
    #[serde(rename = "actionID")]
    pub(crate) action_id: String,
    #[serde(rename = "oldToolRef")]
    pub(crate) old_tool_ref: String,
    #[serde(rename = "newToolRef")]
    pub(crate) new_tool_ref: String,
    #[serde(rename = "expectedActiveGeneration")]
    pub(crate) expected_active_generation: u64,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SelectionOutcome {
    #[serde(rename = "actionID")]
    pub(crate) action_id: String,
    pub(crate) result: String,
    #[serde(rename = "oldToolRef")]
    pub(crate) old_tool_ref: String,
    #[serde(rename = "newToolRef")]
    pub(crate) new_tool_ref: String,
    #[serde(rename = "activeGeneration")]
    pub(crate) active_generation: u64,
    #[serde(rename = "reasonCode", skip_serializing_if = "Option::is_none")]
    pub(crate) reason_code: Option<String>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ToolIndex {
    #[serde(rename = "schemaVersion")]
    pub(crate) schema_version: String,
    pub(crate) records: Vec<ToolRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) selection: Option<Selection>,
}

/// Unregistered-tool projections only. Matching a fresh, published Provider
/// identity is deliberately not inferred from stored metadata.
pub fn decode_tools(bytes: &[u8]) -> Result<DecodedStore, DecodeError> {
    let (index, document) = read_tools(bytes)?;
    let projection = Value::Array(
        index
            .records
            .iter()
            .map(|r| tool_projection(&index, r, published_identity(&r.executable_sha256)))
            .collect(),
    );
    Ok(DecodedStore {
        document,
        projection,
    })
}

/// Swift `readIndex`'s bounded schema, record and selection-ledger checks
/// over the strictly decoded index, and its re-encoded bytes.
pub(crate) fn read_tools(bytes: &[u8]) -> Result<(ToolIndex, Vec<u8>), DecodeError> {
    let (index, document) = roundtrip::<ToolIndex>(bytes, 4 * 1024 * 1024, false)?;
    if !["arkdeck.bootstrap-tools/1", "arkdeck.bootstrap-tools/2"]
        .contains(&index.schema_version.as_str())
        || index.records.len() > 128
        || !index
            .records
            .windows(2)
            .all(|pair| pair[0].reference < pair[1].reference)
        || index.records.iter().any(|r| {
            !digest(&r.content_digest)
                || r.reference != format!("tool:sha256:{}", r.content_digest)
                || !digest(&r.executable_sha256)
                || !r.quarantine_sha256.as_deref().is_none_or(digest)
                || !(1..=268_435_456).contains(&r.byte_count)
                || !r.trust.well_formed()
                || !timestamp(&r.registered_at)
                || r.dependencies.len() > 1
                || r.dependencies.iter().any(|d| {
                    d.name != "libusb_shared.dylib"
                        || !digest(&d.sha256)
                        || !(1..=33_554_432).contains(&d.byte_count)
                        || !d.quarantine_sha256.as_deref().is_none_or(digest)
                        || !d.trust.well_formed()
                })
                || !u64::try_from(r.generation)
                    .ok()
                    .is_some_and(|g| state(&r.state, g, &r.references))
        })
        || !selection_valid(&index)
    {
        return Err(DecodeError::Header);
    }
    Ok((index, document))
}

/// A record's `arkdeck.runtime-tool/1` row in `index`, with the published
/// identity its executable matches, if any.
pub(crate) fn tool_projection(index: &ToolIndex, r: &ToolRecord, identity: Option<Value>) -> Value {
    let generation = index
        .selection
        .as_ref()
        .filter(|s| s.active_tool_ref == r.reference)
        .map(|s| s.active_generation.to_string());
    let dependencies: Vec<_> = r
        .dependencies
        .iter()
        .map(|d| {
            json!({
                "name": d.name, "sha256": d.sha256, "byteCount": d.byte_count.to_string(),
                "quarantineSHA256": d.quarantine_sha256, "trust": d.trust.projection(None),
            })
        })
        .collect();
    json!({
        "schemaVersion": "arkdeck.runtime-tool/1", "toolRef": r.reference,
        "kind": "hdc", "platform": "macos", "source": "registeredCopy",
        "generation": r.generation.to_string(), "state": r.state,
        "contentDigest": r.content_digest, "digestAlgorithm": "sha256-jcs",
        "contentSchemaVersion": "arkdeck.tool-content/1",
        "executableSHA256": r.executable_sha256, "byteCount": r.byte_count.to_string(),
        "quarantineSHA256": r.quarantine_sha256, "registeredAt": r.registered_at,
        "trust": r.trust.projection(identity), "dependencies": dependencies,
        "dependencyLayout": "hdc-sibling-libusb/1", "relocatable": r.relocatable,
        "selected": r.references.iter().any(|o| o.kind == "activeSelection"),
        "activeSelectionGeneration": generation, "references": r.references,
        "contentRetained": true,
    })
}

fn selection_valid(index: &ToolIndex) -> bool {
    let Some(s) = &index.selection else {
        return true;
    };
    let active_owner = |r: &ToolRecord| {
        r.references
            .iter()
            .any(|o| o.kind == "activeSelection" && o.id == "runtime-hdc-selection")
    };
    let available = |reference: &str| {
        index
            .records
            .iter()
            .find(|r| r.reference == reference && r.state == "available")
    };
    if index.schema_version != "arkdeck.bootstrap-tools/2"
        || s.active_generation == 0
        || !available(&s.active_tool_ref).is_some_and(active_owner)
        || !index
            .records
            .iter()
            .all(|r| active_owner(r) == (r.reference == s.active_tool_ref))
        || (s.pending.is_some() && s.last_outcome.is_some())
    {
        return false;
    }
    if let Some(p) = &s.pending {
        let pinned = |reference: &str| {
            available(reference).is_some_and(|r| {
                r.references
                    .iter()
                    .any(|o| o.kind == "controlAction" && o.id == p.action_id)
            })
        };
        if !identifier(&p.action_id)
            || p.old_tool_ref != s.active_tool_ref
            || p.expected_active_generation != s.active_generation
            || p.new_tool_ref == p.old_tool_ref
            || !pinned(&p.old_tool_ref)
            || !pinned(&p.new_tool_ref)
        {
            return false;
        }
    }
    if let Some(o) = &s.last_outcome {
        let exists = |reference: &str| index.records.iter().any(|r| r.reference == reference);
        if !identifier(&o.action_id)
            || !["succeeded", "failed"].contains(&o.result.as_str())
            || o.active_generation != s.active_generation
            || o.old_tool_ref == o.new_tool_ref
            || !exists(&o.old_tool_ref)
            || !exists(&o.new_tool_ref)
            || s.active_tool_ref
                != (if o.result == "succeeded" {
                    &o.new_tool_ref
                } else {
                    &o.old_tool_ref
                })
                .as_str()
            || !o.reason_code.as_deref().is_none_or(identifier)
        {
            return false;
        }
    }
    true
}

/// GJ-1 hop 1: a registered, selected HDC tool and a registered Bundle
/// decode on every host. Their registration times are read by the portable
/// legacy ISO8601DateFormatter check, which on non-macOS hosts once refused
/// every timestamp and so every registry holding a record.
#[cfg(test)]
mod tests {
    use super::*;

    fn tools(registered_at: &str) -> Vec<u8> {
        let reference = format!("tool:sha256:{}", "a".repeat(64));
        serde_json::to_vec(&json!({
            "schemaVersion": "arkdeck.bootstrap-tools/2",
            "records": [{
                "reference": reference, "contentDigest": "a".repeat(64),
                "executableSHA256": "b".repeat(64), "byteCount": 1,
                "registeredAt": registered_at, "trust": {"signature": "unsigned"},
                "dependencies": [], "relocatable": false, "generation": 1,
                "state": "available",
                "references": [{"kind": "activeSelection", "id": "runtime-hdc-selection"}],
            }],
            "selection": {"activeToolRef": reference, "activeGeneration": 3},
        }))
        .unwrap()
    }

    /// A bundle index of one record in this host's form (a Windows record
    /// carries its host tag and signer), or in the other host's.
    fn bundle_index(registered_at: &str, windows: bool) -> Vec<u8> {
        let mut record = json!({
            "reference": format!("bundle:sha256:{}", "c".repeat(64)),
            "digest": "c".repeat(64), "registeredAtUTC": registered_at,
            "byteCount": 0, "entryCount": 1, "generation": 1,
            "state": "available", "references": [],
        });
        if windows {
            record["platform"] = json!("windows");
            record["signer"] = json!("ArkDeck Development Daemon (host-trusted only)");
        }
        serde_json::to_vec(&json!({
            "schemaVersion": "arkdeck.bootstrap-bundles/1",
            "records": [record],
        }))
        .unwrap()
    }

    fn bundles(registered_at: &str) -> Vec<u8> {
        bundle_index(registered_at, cfg!(windows))
    }

    #[test]
    fn each_host_reads_only_its_own_bundle_record_form() {
        let other = bundle_index("2026-09-30T08:15:00Z", !cfg!(windows));
        assert!(matches!(decode_bundles(&other), Err(DecodeError::Header)));
        let decoded = decode_bundles(&bundles("2026-09-30T08:15:00Z")).unwrap();
        let row = &decoded.projection[0];
        if cfg!(windows) {
            assert_eq!(row["platform"], "windows");
            assert_eq!(row["trust"]["policy"], "arkdeck.windows-daemon-package/1");
            assert_eq!(
                row["trust"]["teamIdentifier"],
                "ArkDeck Development Daemon (host-trusted only)"
            );
        } else {
            assert_eq!(row["platform"], "macos");
            assert_eq!(row["trust"]["teamIdentifier"], "8AQTYW5FKR");
        }
    }

    #[test]
    fn registered_tool_and_bundle_decode_on_every_host() {
        for registered_at in ["2026-09-30T08:15:00Z", "2026-09-30T16:15:00+08:00"] {
            let decoded = decode_tools(&tools(registered_at)).unwrap();
            let row = &decoded.projection[0];
            assert_eq!(row["registeredAt"], registered_at);
            assert_eq!(row["selected"], true);
            assert_eq!(row["activeSelectionGeneration"], "3");
            let decoded = decode_bundles(&bundles(registered_at)).unwrap();
            assert_eq!(decoded.projection[0]["registeredAtUTC"], registered_at);
        }
    }

    #[test]
    fn registration_time_outside_the_formatter_shape_fails_closed() {
        for registered_at in [
            "",
            "2026-09-30T08:15:00",
            "2026-02-32T08:15:00Z",
            "2026-09-30T25:00:00Z",
            "2026-09-30 08:15:00Z",
            "2026-09-30T08:15:00.5Z",
            "2026-09-30T08:15:00Z trailing text",
        ] {
            assert!(
                matches!(
                    decode_tools(&tools(registered_at)),
                    Err(DecodeError::Header)
                ),
                "{registered_at:?}"
            );
            assert!(
                matches!(
                    decode_bundles(&bundles(registered_at)),
                    Err(DecodeError::Header)
                ),
                "{registered_at:?}"
            );
        }
    }
}
