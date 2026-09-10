//! Read the actual immutable Artifact inventory before a storage configuration
//! transaction. This reader never publishes, repairs, evicts, or exports bytes.
use arkdeck_platform::{HostDirectory, HostEntryKind};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    io,
    path::{Path, PathBuf},
};

pub struct ArtifactUsage {
    path: PathBuf,
    root: HostDirectory,
    quota: u64,
}
fn invalid() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "Artifact inventory or payload is unreadable",
    )
}
fn object<'a>(
    value: &'a Value,
    required: &[&str],
    optional: &[&str],
) -> io::Result<&'a serde_json::Map<String, Value>> {
    let fields = value.as_object().ok_or_else(invalid)?;
    if required.iter().any(|k| !fields.contains_key(*k))
        || fields
            .keys()
            .any(|k| !required.contains(&k.as_str()) && !optional.contains(&k.as_str()))
    {
        return Err(invalid());
    }
    Ok(fields)
}
fn text<'a>(value: &'a Value, key: &str) -> io::Result<&'a str> {
    value[key].as_str().ok_or_else(invalid)
}
fn optional_text(value: &Value, key: &str) -> bool {
    value.get(key).is_none_or(|v| v.is_null() || v.is_string())
}
fn optional_integer(value: &Value, key: &str) -> bool {
    value
        .get(key)
        .is_none_or(|v| v.is_null() || v.as_i64().is_some())
}
fn artifact_id(value: &str) -> bool {
    value
        .strip_prefix("ART-MISSING-")
        .or_else(|| value.strip_prefix("ART-"))
        .is_some_and(|s| {
            s.len() == 32
                && s.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
}
fn metadata(value: &Value) -> io::Result<()> {
    let strings = [
        "artifactID",
        "jobID",
        "sessionID",
        "stepID",
        "name",
        "mediaType",
        "sha256",
        "createdAtUTC",
        "providerID",
        "sourceOperation",
        "privacy",
    ];
    let mut required = strings.to_vec();
    required.extend([
        "byteCount",
        "bindingSnapshot",
        "retention",
        "status",
        "redactionApplied",
    ]);
    object(value, &required, &["derivation", "observationWindow"])?;
    for field in strings {
        text(value, field)?;
    }
    if value["byteCount"].as_i64().is_none_or(|n| n < 0)
        || !value["redactionApplied"].is_boolean()
        || !["standard", "sensitive"].contains(&text(value, "privacy")?)
    {
        return Err(invalid());
    }
    let binding = &value["bindingSnapshot"];
    object(
        binding,
        &["targetID"],
        &["bindingRevision", "stableIdentitySHA256"],
    )?;
    text(binding, "targetID")?;
    if !optional_integer(binding, "bindingRevision")
        || !optional_text(binding, "stableIdentitySHA256")
    {
        return Err(invalid());
    }
    let retention = &value["retention"];
    object(retention, &["retentionClass", "pinned"], &["deadlineUTC"])?;
    if !["default", "shortLived", "pinnedUntilVerified"]
        .contains(&text(retention, "retentionClass")?)
        || !retention["pinned"].is_boolean()
        || !optional_text(retention, "deadlineUTC")
    {
        return Err(invalid());
    }
    if let Some(window) = value.get("observationWindow").filter(|v| !v.is_null()) {
        object(window, &["startUTC", "endUTC"], &[])?;
        text(window, "startUTC")?;
        text(window, "endUTC")?;
    }
    if let Some(derived) = value.get("derivation").filter(|v| !v.is_null()) {
        let strings = [
            "analyzerRef",
            "analyzerVersion",
            "sourceArtifactID",
            "sourceSHA256",
            "toolSHA256",
            "parserSHA256",
            "parserVersion",
            "parserUpstreamRevision",
            "parserBuildRecipeVersion",
            "parserAdapterVersion",
            "schemaAdapterVersion",
        ];
        let numbers = [
            "sourceByteCount",
            "indexSchemaVersion",
            "timeoutMs",
            "maxRows",
            "maxEvents",
            "maxOutputBytes",
        ];
        let optional_strings = ["requestCommand", "requestKind"];
        let optional_numbers = [
            "requestTimestampNs",
            "requestStartNs",
            "requestEndNs",
            "requestProcessKey",
            "requestPID",
            "requestThreadKey",
            "requestTID",
            "requestThresholdNs",
            "requestLimit",
        ];
        let mut required = strings.to_vec();
        required.extend(numbers);
        let mut optional = optional_strings.to_vec();
        optional.extend(optional_numbers);
        object(derived, &required, &optional)?;
        for key in strings {
            text(derived, key)?;
        }
        if numbers.iter().any(|k| derived[*k].as_i64().is_none())
            || optional_numbers
                .iter()
                .any(|k| !optional_integer(derived, k))
            || optional_strings.iter().any(|k| !optional_text(derived, k))
        {
            return Err(invalid());
        }
    }
    let status = value["status"].as_object().ok_or_else(invalid)?;
    if status.len() != 1 {
        return Err(invalid());
    }
    if let Some(published) = status.get("published") {
        object(published, &[], &[])?;
    } else if let Some(missing) = status.get("missing") {
        object(missing, &["reason"], &[])?;
        text(missing, "reason")?;
    } else if let Some(truncated) = status.get("truncated") {
        object(truncated, &["atBytes"], &[])?;
        if truncated["atBytes"].as_i64().is_none() {
            return Err(invalid());
        }
    } else {
        return Err(invalid());
    }
    Ok(())
}
impl ArtifactUsage {
    pub fn open(path: &Path, quota: u64) -> io::Result<Self> {
        if quota == 0 || quota > i64::MAX as u64 {
            return Err(invalid());
        }
        Ok(Self {
            path: path.into(),
            root: HostDirectory::open(path)?,
            quota,
        })
    }
    pub fn status(&self) -> io::Result<Value> {
        self.root.validate_path(&self.path)?;
        let names = self.root.names(usize::MAX)?;
        let mut used = 0_u64;
        for name in &names {
            let (kind, _) = self.root.owned_kind_and_size(name)?;
            if kind == HostEntryKind::Regular && name == "cleanup-debt.json" {
                continue;
            }
            if kind != HostEntryKind::Directory {
                return Err(invalid());
            }
            let job = self.root.child(name)?;
            if name == ".imports-v1" {
                continue;
            }
            if name.is_empty()
                || name.len() > 128
                || !name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
            {
                return Err(invalid());
            }
            let index = match job.read("index.json", 16 * 1024 * 1024) {
                Ok(bytes) => bytes,
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e),
            };
            let document: Value = arkdeck_contract::strict_json(&index).map_err(|_| invalid())?;
            object(&document, &["schemaVersion", "artifacts"], &[])?;
            if document["schemaVersion"] != "1.0.0" {
                return Err(invalid());
            }
            let mut ids = HashSet::new();
            let mut artifact_names = HashSet::new();
            for row in document["artifacts"].as_array().ok_or_else(invalid)? {
                metadata(row)?;
                let id = text(row, "artifactID")?;
                let name_key =
                    crate::canonical_host_text(text(row, "name")?).map_err(|_| invalid())?;
                if text(row, "jobID")? != name
                    || !artifact_id(id)
                    || !ids.insert(id)
                    || !artifact_names.insert(name_key)
                {
                    return Err(invalid());
                }
                if row["status"].get("published").is_some() {
                    let count = row["byteCount"].as_u64().ok_or_else(invalid)?;
                    job.verify_payload(id, count, text(row, "sha256")?)?;
                    used = used
                        .checked_add(count)
                        .filter(|n| *n <= i64::MAX as u64)
                        .ok_or_else(invalid)?;
                }
            }
            if job.read("index.json", 16 * 1024 * 1024)? != index {
                return Err(invalid());
            }
            job.validate_path(&self.path.join(name))?;
        }
        if self.root.names(usize::MAX)? != names {
            return Err(invalid());
        }
        self.root.validate_path(&self.path)?;
        Ok(
            json!({"schemaVersion":"arkdeck.artifact-storage-status/1","rootReference":"arkdeck-runtime://artifacts",
            "policy":"refuseNewWorkNeverEvict","totalBytes":self.quota.to_string(),"usedBytes":used.to_string(),
            "remainingBytes":self.quota.saturating_sub(used).to_string()}),
        )
    }
}
