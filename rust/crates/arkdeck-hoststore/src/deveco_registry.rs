//! Current Swift DevEco metadata schema. Offline decoding does not validate
//! external content; only the read owner revalidates available registrations.
use crate::{DecodeError, DecodedStore, roundtrip};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Trust {
    pub signature: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub identifier: Option<String>,
    #[serde(rename = "teamIdentifier", skip_serializing_if = "Option::is_none")]
    pub team: Option<String>,
    #[serde(
        rename = "codeDirectorySHA256",
        skip_serializing_if = "Option::is_none"
    )]
    pub directory: Option<String>,
}
impl Trust {
    pub(crate) fn native(value: arkdeck_platform::NativeCodeSignature) -> Self {
        Self {
            signature: value.signature.into(),
            identifier: value.identifier,
            team: value.team_identifier,
            directory: value.code_directory_sha256,
        }
    }
    fn well_formed(&self) -> bool {
        ["unsigned", "adHoc", "verified"].contains(&self.signature.as_str())
            && [&self.identifier, &self.team].into_iter().all(|s| {
                s.as_deref().is_none_or(|s| {
                    !s.is_empty() && s.len() <= 256 && !s.chars().any(|c| c < ' ' || c == '\u{7f}')
                })
            })
            && if self.signature == "unsigned" {
                self.identifier.is_none() && self.team.is_none() && self.directory.is_none()
            } else {
                self.directory.as_deref().is_none_or(digest)
            }
    }
    pub(crate) fn value(&self) -> Value {
        json!({"policy":"arkdeck.host-tool-inspection/1","signature":self.signature,"signingIdentifier":self.identifier,"teamIdentifier":self.team,"codeDirectoryIdentitySHA256":self.directory,"platformTrust":"unverified","executionAssessment":"notPerformed","registeredIdentity":false,"profileReferences":[],"toolVersion":null,"versionSource":null})
    }
}
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct RootIdentity {
    pub path: String,
    pub device: u64,
    pub inode: u64,
    pub modified_seconds: i64,
    pub modified_nanos: i64,
    pub changed_seconds: i64,
    pub changed_nanos: i64,
}
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct Child {
    pub role: String,
    pub relative_path: String,
    pub device: u64,
    pub inode: u64,
    pub byte_count: i64,
    pub modified_seconds: i64,
    pub modified_nanos: i64,
    pub changed_seconds: i64,
    pub changed_nanos: i64,
    pub sha256: String,
    pub executable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trust: Option<Trust>,
}
impl Child {
    pub(crate) fn value(&self) -> Value {
        json!({"role":self.role,"sha256":self.sha256,"byteCount":self.byte_count.to_string(),"executable":self.executable,"trust":self.trust.as_ref().map(Trust::value)})
    }
}
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Owner {
    pub kind: String,
    pub id: String,
}
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct Record {
    pub reference: String,
    pub content_digest: String,
    pub root: RootIdentity,
    pub product_version: String,
    pub build_number: String,
    pub sdk_version: String,
    pub api_version: String,
    #[serde(rename = "registeredAtUTC")]
    pub registered_at: String,
    pub bundle_trust: Trust,
    pub children: Vec<Child>,
    pub generation: u64,
    pub state: String,
    pub references: Vec<Owner>,
}
impl Record {
    pub(crate) fn value(&self) -> Value {
        json!({"schemaVersion":"arkdeck.runtime-tool/1","toolRef":self.reference,"kind":"deveco","platform":"macos","source":"registeredRoot","generation":self.generation.to_string(),"state":self.state,"contentDigest":self.content_digest,"digestAlgorithm":"sha256-jcs","contentSchemaVersion":"arkdeck.deveco-toolchain-content/2","productVersion":self.product_version,"buildNumber":self.build_number,"sdkVersion":self.sdk_version,"apiVersion":self.api_version,"trust":self.bundle_trust.value(),"childTools":self.children.iter().map(Child::value).collect::<Vec<_>>(),"selected":false,"references":self.references,"contentRetained":false})
    }
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct Index {
    pub schema_version: String,
    pub records: Vec<Record>,
}
pub(crate) fn digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub(crate) fn identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
}
pub(crate) fn version(value: &str) -> bool {
    identifier(value) && value.bytes().any(|b| b.is_ascii_digit())
}
fn owner_identifier(value: &str) -> bool {
    identifier(value) && value.as_bytes()[0].is_ascii_alphanumeric()
}
pub(crate) fn read_index(bytes: &[u8]) -> Result<(Index, Vec<u8>), DecodeError> {
    let (index, document) = roundtrip::<Index>(bytes, 4 * 1024 * 1024, false)?;
    if index.schema_version != "arkdeck.bootstrap-deveco-toolchains/1"
        || index.records.len() > 32
        || !index
            .records
            .windows(2)
            .all(|r| r[0].reference < r[1].reference)
    {
        return Err(DecodeError::Header);
    }
    for record in &index.records {
        let roles = record
            .children
            .iter()
            .map(|r| r.role.as_str())
            .collect::<std::collections::BTreeSet<_>>();
        let mut owners = std::collections::BTreeSet::new();
        if record.reference != format!("toolchain:sha256:{}", record.content_digest)
            || !digest(&record.content_digest)
            || !record.root.path.starts_with('/')
            || !version(&record.product_version)
            || !identifier(&record.build_number)
            || !version(&record.sdk_version)
            || !identifier(&record.api_version)
            || !record.bundle_trust.well_formed()
            || record.children.len() != 5
            || roles
                != [
                    "productManifest",
                    "sdkManifest",
                    "node",
                    "hvigor",
                    "signedResourceEnvelope",
                ]
                .into_iter()
                .collect()
            || !record
                .children
                .iter()
                .all(|r| digest(&r.sha256) && r.byte_count > 0)
            || !((record.state == "available" && record.generation == 1)
                || (record.state == "removed"
                    && record.generation == 2
                    && record.references.is_empty()))
            || record.references.len() > 1024
            || !record.references.iter().all(|r| {
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
                .contains(&r.kind.as_str())
                    && owner_identifier(&r.id)
                    && owners.insert((&r.kind, &r.id))
            })
            || arkdeck_platform::host_legacy_iso8601(&record.registered_at) != Some(true)
        {
            return Err(DecodeError::Header);
        }
    }
    Ok((index, document))
}
pub fn decode_deveco_toolchains(bytes: &[u8]) -> Result<DecodedStore, DecodeError> {
    let (index, document) = read_index(bytes)?;
    Ok(DecodedStore {
        document,
        projection: Value::Array(index.records.iter().map(Record::value).collect()),
    })
}
