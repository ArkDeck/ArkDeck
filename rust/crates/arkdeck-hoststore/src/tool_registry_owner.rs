//! Read-only owner for an existing initialized bootstrap Tool registry.
//! Every returned row has undergone fresh content and native signing checks.
//! This API neither selects tools nor admits execution.
use crate::{
    decode_bundles, decode_tools,
    tool_content::{ToolContent, inspect_tool_content},
};
use arkdeck_platform::{HostDirectory, NativeCodeSignature};
use serde_json::Value;
use std::{
    io,
    path::{Path, PathBuf},
};
const MAXIMUM_INDEX: usize = 4 * 1024 * 1024;
pub struct ToolRegistryReadStore {
    root: HostDirectory,
    path: PathBuf,
}
fn corrupt() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "bootstrap tool registry or content is unreadable",
    )
}
fn read_error(error: io::Error) -> io::Error {
    if error.kind() == io::ErrorKind::WouldBlock {
        error
    } else {
        corrupt()
    }
}
fn same_trust(record: &Value, trust: &NativeCodeSignature) -> bool {
    record["signature"] == trust.signature
        && record["identifier"].as_str() == trust.identifier.as_deref()
        && record["teamIdentifier"].as_str() == trust.team_identifier.as_deref()
        && record["codeDirectorySHA256"].as_str() == trust.code_directory_sha256.as_deref()
}
fn matches(record: &Value, content: &ToolContent) -> bool {
    record["contentDigest"] == content.digest
        && record["executableSHA256"] == content.sha256
        && record["byteCount"].as_u64() == Some(content.byte_count)
        && record["quarantineSHA256"].as_str() == content.quarantine_sha256.as_deref()
        && record["relocatable"].as_bool() == Some(content.relocatable)
        && same_trust(&record["trust"], &content.trust)
        && record["dependencies"].as_array().is_some_and(|rows| {
            rows.len() == content.dependencies.len()
                && rows.iter().zip(&content.dependencies).all(|(r, d)| {
                    r["name"] == d.name
                        && r["sha256"] == d.sha256
                        && r["byteCount"].as_u64() == Some(d.byte_count)
                        && r["quarantineSHA256"].as_str() == d.quarantine_sha256.as_deref()
                        && same_trust(&r["trust"], &d.trust)
                })
        })
}
impl ToolRegistryReadStore {
    /// Requires a pre-existing bootstrap store; initialization and registration
    /// remain separate owner operations. No directory or lock file is created.
    pub fn open_existing(path: &Path) -> io::Result<Self> {
        Ok(Self {
            root: HostDirectory::open(path)?,
            path: path.into(),
        })
    }
    pub fn list(&self) -> io::Result<Vec<Value>> {
        self.read(None).map_err(read_error)
    }
    fn read(&self, reference: Option<&str>) -> io::Result<Vec<Value>> {
        self.root.validate_path(&self.path)?;
        let lock = self
            .root
            .try_lock_existing_strict(".lock")?
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "bootstrap owner lock unavailable",
                )
            })?;
        let bundles = self.root.read("bundles.json", MAXIMUM_INDEX)?;
        decode_bundles(&bundles).map_err(|_| corrupt())?;
        let bytes = self.root.read("tools.json", MAXIMUM_INDEX)?;
        let decoded = decode_tools(&bytes).map_err(|_| corrupt())?;
        let document: Value = serde_json::from_slice(&decoded.document).map_err(|_| corrupt())?;
        for record in document["records"].as_array().ok_or_else(corrupt)? {
            if reference.is_some_and(|r| record["reference"] != r) {
                continue;
            }
            let digest = record["contentDigest"].as_str().ok_or_else(corrupt)?;
            // The strict decoder proved the digest consists of exactly 64 hex bytes.
            let name = format!("tool-{digest}.hdc");
            let path = self.path.join(&name);
            let held = self.root.child(&name)?;
            let measured = inspect_tool_content(&path)?;
            if !matches(record, &measured) {
                return Err(corrupt());
            }
            held.validate_path(&path)?;
        }
        if self.root.read("tools.json", MAXIMUM_INDEX)? != bytes
            || self.root.read("bundles.json", MAXIMUM_INDEX)? != bundles
        {
            return Err(corrupt());
        }
        lock.validate_link(&self.root, ".lock")?;
        self.root.validate_path(&self.path)?;
        Ok(decoded
            .projection
            .as_array()
            .ok_or_else(corrupt)?
            .iter()
            .filter(|v| reference.is_none_or(|r| v["toolRef"] == r))
            .cloned()
            .collect())
    }
    pub fn inspect(&self, reference: &str) -> io::Result<Value> {
        if !reference.strip_prefix("tool:sha256:").is_some_and(|s| {
            s.len() == 64
                && s.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        }) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "exact HDC tool reference is required",
            ));
        }
        self.read(Some(reference))
            .map_err(read_error)?
            .into_iter()
            .find(|v| v["toolRef"] == reference)
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, "tool reference is not registered")
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt},
    };
    fn write(root: &Path, name: &str, value: &Value) {
        fs::write(root.join(name), serde_json::to_vec(value).unwrap()).unwrap();
        fs::set_permissions(root.join(name), fs::Permissions::from_mode(0o600)).unwrap();
    }
    fn trust(v: &NativeCodeSignature) -> Value {
        let mut value = json!({"signature":v.signature,"identifier":v.identifier,
        "teamIdentifier":v.team_identifier,"codeDirectorySHA256":v.code_directory_sha256});
        value.as_object_mut().unwrap().retain(|_, v| !v.is_null());
        value
    }
    #[test]
    fn existing_registry_rechecks_native_bytes_and_durable_claims() {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("tool-registry-{nonce:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        fs::DirBuilder::new()
            .mode(0o700)
            .create(root.join("fixture"))
            .unwrap();
        fs::copy("/usr/bin/true", root.join("fixture/hdc")).unwrap();
        fs::set_permissions(root.join("fixture/hdc"), fs::Permissions::from_mode(0o700)).unwrap();
        let content = inspect_tool_content(&root.join("fixture")).unwrap();
        let name = format!("tool-{}.hdc", content.digest);
        fs::rename(root.join("fixture"), root.join(&name)).unwrap();
        fs::write(root.join(".lock"), b"").unwrap();
        fs::set_permissions(root.join(".lock"), fs::Permissions::from_mode(0o600)).unwrap();
        write(
            &root,
            "bundles.json",
            &json!({"schemaVersion":"arkdeck.bootstrap-bundles/1","records":[]}),
        );
        let reference = format!("tool:sha256:{}", content.digest);
        let mut index = json!({"schemaVersion":"arkdeck.bootstrap-tools/2","records":[{
            "reference":reference,"contentDigest":content.digest,"executableSHA256":content.sha256,
            "registeredAt":"2026-09-11T00:00:00Z","byteCount":content.byte_count,"quarantineSHA256":content.quarantine_sha256,
            "trust":trust(&content.trust),"dependencies":[],"relocatable":content.relocatable,"generation":1,"state":"available","references":[]}]});
        if content.quarantine_sha256.is_none() {
            index["records"][0]
                .as_object_mut()
                .unwrap()
                .remove("quarantineSHA256");
        }
        write(&root, "tools.json", &index);
        let store = ToolRegistryReadStore::open_existing(&root).unwrap();
        let value = store.inspect(&reference).unwrap();
        assert_eq!(value["toolRef"], reference);
        assert_eq!(value["trust"]["executionAssessment"], "notPerformed");
        assert_eq!(value["trust"]["registeredIdentity"], false);
        let mut unrelated = index["records"][0].clone();
        unrelated["contentDigest"] = json!("0".repeat(64));
        unrelated["reference"] = json!(format!("tool:sha256:{}", "0".repeat(64)));
        index["records"]
            .as_array_mut()
            .unwrap()
            .insert(0, unrelated);
        write(&root, "tools.json", &index);
        assert_eq!(store.inspect(&reference).unwrap(), value);
        assert!(store.list().is_err());
        index["records"].as_array_mut().unwrap().remove(0);
        write(&root, "tools.json", &index);
        let guard = HostDirectory::open(&root)
            .unwrap()
            .lock_document(".lock")
            .unwrap();
        assert_eq!(store.list().unwrap_err().kind(), io::ErrorKind::WouldBlock);
        drop(guard);
        index["records"][0]["trust"] = json!({"signature":"unsigned"});
        write(&root, "tools.json", &index);
        assert!(store.list().is_err());
        index["records"][0]["trust"] = trust(&content.trust);
        write(&root, "tools.json", &index);
        fs::write(root.join(&name).join("hdc"), b"changed").unwrap();
        assert!(store.list().is_err());
    }
}
