//! Retire one unreferenced host tool registration without deleting any bytes or
//! changing selection, reference ownership, installation, or execution state.
use crate::{DevEcoRegistryStore, ToolRegistryStore, decode_bundles, decode_tools};
use arkdeck_contract::{WireError, canonical_json};
use arkdeck_platform::{DocumentPublishError, HostDirectory, HostReadLock};
use serde_json::{Value, json};
use std::{fs::Metadata, io, os::unix::fs::MetadataExt, path::Path};
const MAX_INDEX: usize = 4 * 1024 * 1024;
const BUNDLES: &str = "bundles.json";
const TOOLS: &str = "tools.json";
const DEVECO: &str = "deveco-toolchains.json";

fn failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(serde_json::Map::from_iter([
            ("phase".into(), json!("bootstrapRegistryOwner")),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}
fn unreadable(_: impl std::fmt::Debug) -> WireError {
    failure(
        "recordUnreadable",
        "registered host tool failed content, identity or registry validation",
    )
}
fn unknown() -> WireError {
    failure(
        "outcomeUnknown",
        "host tool index publication is uncertain; inspect the exact reference",
    )
}
fn publication(error: DocumentPublishError, name: &str) -> WireError {
    match error {
        DocumentPublishError::BeforePublication(_) if name == TOOLS || name == DEVECO => {
            failure("ioFailure", "cannot publish host tool index")
        }
        DocumentPublishError::BeforePublication(error) => unreadable(error),
        DocumentPublishError::OutcomeUnknown(_) => unknown(),
    }
}
fn same_metadata(a: &Metadata, b: &Metadata) -> bool {
    a.dev() == b.dev()
        && a.ino() == b.ino()
        && a.mode() == b.mode()
        && a.uid() == b.uid()
        && a.gid() == b.gid()
        && a.nlink() == b.nlink()
        && a.len() == b.len()
        && a.mtime() == b.mtime()
        && a.mtime_nsec() == b.mtime_nsec()
        && a.ctime() == b.ctime()
        && a.ctime_nsec() == b.ctime_nsec()
}
struct IndexSnapshot {
    bytes: Vec<u8>,
    metadata: Metadata,
}
fn find(document: &Value, reference: &str) -> Result<usize, WireError> {
    if !reference
        .strip_prefix("tool:sha256:")
        .is_some_and(|digest| {
            digest.len() == 64
                && digest
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
    {
        return Err(failure(
            "invalidInput",
            "expected a content-addressed HDC tool reference",
        ));
    }
    document["records"]
        .as_array()
        .ok_or_else(|| unreadable("records"))?
        .iter()
        .position(|record| record["reference"] == reference)
        .ok_or_else(|| failure("resourceNotFound", "tool reference does not exist"))
}
// Pure metadata transition, invoked only after whole-index strict decoding and
// fresh native verification of the exact target. No trust callback exists.
fn retire_record(document: &mut Value, position: usize) -> Result<bool, WireError> {
    let record = &mut document["records"][position];
    if record["state"] == "removed" {
        return Ok(false);
    }
    if !record["references"]
        .as_array()
        .ok_or_else(|| unreadable("references"))?
        .is_empty()
    {
        return Err(failure(
            "resourceConflict",
            "tool is selected or retained by an installation, Job, execution, recovery, action or lease",
        ));
    }
    record["state"] = json!("removed");
    record["generation"] = json!(2);
    // Swift saveIndex upgrades legacy metadata on a real write, but a repeated
    // retired receipt must not rewrite or upgrade an existing legacy index.
    document["schemaVersion"] = json!("arkdeck.bootstrap-tools/2");
    Ok(true)
}
impl ToolRegistryStore {
    /// Preserve Swift's order: shared bundle index, tool index/selection, exact
    /// reference, literal expected generation `1`, native target verification,
    /// idempotent removed result, then reference protection and publication.
    pub fn retire(&self, reference: &str, expected_generation: &str) -> Result<Value, WireError> {
        let owner = RetirementRoot {
            root: &self.root,
            path: &self.path,
        };
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let lock = self.root.lock_document(".lock").map_err(|error| {
            if error.kind() == io::ErrorKind::WouldBlock {
                failure(
                    "resourceConflict",
                    "another bootstrap operation holds the store",
                )
            } else {
                unreadable(error)
            }
        })?;
        owner.retirement_binding(&lock)?;
        let bundles = owner.retirement_load(&lock, BUNDLES)?;
        decode_bundles(&bundles.bytes).map_err(unreadable)?;
        let tools = owner.retirement_load(&lock, TOOLS)?;
        owner.retirement_index(BUNDLES, &bundles)?;
        let decoded = decode_tools(&tools.bytes).map_err(unreadable)?;
        let mut document: Value = serde_json::from_slice(&decoded.document).map_err(unreadable)?;
        let position = find(&document, reference)?;
        if expected_generation != "1" {
            return Err(failure(
                "resourceConflict",
                "host tool generation does not match",
            ));
        }
        // Swift wraps every content, dependency, identity and trust failure in
        // recordUnreadable; do not expose a different admission error here.
        self.verify_record(&document["records"][position])
            .map_err(unreadable)?;
        owner.retirement_binding(&lock)?;
        owner.retirement_index(BUNDLES, &bundles)?;
        owner.retirement_index(TOOLS, &tools)?;
        if !retire_record(&mut document, position)? {
            return Ok(decoded.projection[position].clone());
        }
        let encoded = canonical_json(&document).map_err(unreadable)?;
        if encoded.len() > MAX_INDEX {
            return Err(failure(
                "quotaExceeded",
                "tool index exceeds its bounded storage",
            ));
        }
        let updated = decode_tools(&encoded).map_err(unreadable)?;
        owner.retirement_binding(&lock)?;
        owner.retirement_index(BUNDLES, &bundles)?;
        owner.retirement_index(TOOLS, &tools)?;
        self.root
            .publish_document(TOOLS, &encoded, MAX_INDEX)
            .map_err(|error| publication(error, TOOLS))?;
        // Once metadata was published, uncertain shared bindings or readback
        // cannot be called a known failure or permit automatic replay.
        let result = (|| {
            owner.retirement_binding(&lock)?;
            owner.retirement_index(BUNDLES, &bundles)?;
            if self.root.read(TOOLS, MAX_INDEX).map_err(unreadable)? != encoded {
                return Err(unreadable("published index changed"));
            }
            Ok(())
        })();
        result.map_err(|_: WireError| unknown())?;
        Ok(updated.projection[position].clone())
    }
}
struct RetirementRoot<'a> {
    root: &'a HostDirectory,
    path: &'a Path,
}
impl RetirementRoot<'_> {
    fn retirement_binding(&self, lock: &HostReadLock) -> Result<(), WireError> {
        lock.validate_link(self.root, ".lock").map_err(unreadable)?;
        self.root.validate_path(self.path).map_err(unreadable)
    }
    fn retirement_index(&self, name: &str, snapshot: &IndexSnapshot) -> Result<(), WireError> {
        if self.root.read(name, MAX_INDEX).map_err(unreadable)? != snapshot.bytes
            || !same_metadata(
                &snapshot.metadata,
                &self.root.document_metadata(name).map_err(unreadable)?,
            )
        {
            return Err(unreadable("shared index changed"));
        }
        Ok(())
    }
    fn retirement_load(&self, lock: &HostReadLock, name: &str) -> Result<IndexSnapshot, WireError> {
        match self.root.document_metadata(name) {
            Ok(_) => (),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let names = self.root.names(4096).map_err(unreadable)?;
                let safe = if name == BUNDLES {
                    names == [".lock"]
                } else if name == DEVECO {
                    true
                } else {
                    !names
                        .iter()
                        .any(|name| name.starts_with("tool-") || name.starts_with(".tool-"))
                };
                if !safe {
                    return Err(unreadable("missing index beside retained state"));
                }
                self.retirement_binding(lock)?;
                let bytes = if name == BUNDLES {
                    br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-bundles/1"}"#.as_slice()
                } else if name == DEVECO {
                    br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-deveco-toolchains/1"}"#
                        .as_slice()
                } else {
                    br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-tools/2"}"#.as_slice()
                };
                self.root
                    .publish_document(name, bytes, MAX_INDEX)
                    .map_err(|error| publication(error, name))?;
                self.retirement_binding(lock).map_err(|_| unknown())?;
            }
            Err(error) => return Err(unreadable(error)),
        }
        let metadata = self.root.document_metadata(name).map_err(unreadable)?;
        let bytes = self.root.read(name, MAX_INDEX).map_err(unreadable)?;
        let snapshot = IndexSnapshot { bytes, metadata };
        self.retirement_index(name, &snapshot)?;
        Ok(snapshot)
    }
}

impl DevEcoRegistryStore {
    /// Retire metadata only. Removed DevEco registrations do not retain their
    /// external content and therefore return without inspecting the old root.
    pub fn retire(&self, reference: &str, expected_generation: &str) -> Result<Value, WireError> {
        let owner = RetirementRoot {
            root: &self.root,
            path: &self.path,
        };
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let lock = self.root.lock_document(".lock").map_err(|error| {
            if error.kind() == io::ErrorKind::WouldBlock {
                failure(
                    "resourceConflict",
                    "another bootstrap operation holds the store",
                )
            } else {
                unreadable(error)
            }
        })?;
        owner.retirement_binding(&lock)?;
        let bundles = owner.retirement_load(&lock, BUNDLES)?;
        decode_bundles(&bundles.bytes).map_err(unreadable)?;
        let previous = owner.retirement_load(&lock, DEVECO)?;
        let (mut index, _) =
            crate::deveco_registry::read_index(&previous.bytes).map_err(unreadable)?;
        owner.retirement_index(BUNDLES, &bundles)?;
        if !reference
            .strip_prefix("toolchain:sha256:")
            .is_some_and(crate::deveco_registry::digest)
        {
            return Err(failure(
                "invalidInput",
                "expected a content-addressed toolchain reference",
            ));
        }
        let position = index
            .records
            .iter()
            .position(|record| record.reference == reference)
            .ok_or_else(|| failure("resourceNotFound", "toolchain reference does not exist"))?;
        if expected_generation != "1" {
            return Err(failure(
                "resourceConflict",
                "DevEco toolchain generation does not match",
            ));
        }
        let record = &mut index.records[position];
        if record.state == "available" {
            crate::deveco_content::verify(record).map_err(|error| {
                let code = if error
                    .get_ref()
                    .is_some_and(|inner| inner.is::<arkdeck_platform::DevEcoIdentityChanged>())
                {
                    "fileIdentityChanged"
                } else if error
                    .get_ref()
                    .is_some_and(|inner| inner.is::<arkdeck_platform::DevEcoInputTooLarge>())
                {
                    "inputTooLarge"
                } else if error.raw_os_error().is_some() {
                    "ioFailure"
                } else {
                    match error.kind() {
                        io::ErrorKind::PermissionDenied => "admissionDenied",
                        io::ErrorKind::NotFound => "fileIdentityChanged",
                        _ => "recordUnreadable",
                    }
                };
                failure(
                    code,
                    "registered DevEco root, manifests or child tools failed verification",
                )
            })?;
        }
        owner.retirement_binding(&lock)?;
        owner.retirement_index(BUNDLES, &bundles)?;
        owner.retirement_index(DEVECO, &previous)?;
        if record.state == "removed" {
            return Ok(record.value());
        }
        if !record.references.is_empty() {
            return Err(failure(
                "resourceConflict",
                "DevEco toolchain is retained by a workspace preset",
            ));
        }
        record.state = "removed".into();
        record.generation = 2;
        let value = record.value();
        let encoded = canonical_json(&serde_json::to_value(&index).map_err(unreadable)?)
            .map_err(unreadable)?;
        if encoded.len() > MAX_INDEX {
            return Err(failure(
                "quotaExceeded",
                "DevEco toolchain index exceeds its storage bound",
            ));
        }
        crate::deveco_registry::read_index(&encoded).map_err(unreadable)?;
        owner.retirement_binding(&lock)?;
        owner.retirement_index(BUNDLES, &bundles)?;
        owner.retirement_index(DEVECO, &previous)?;
        self.root
            .publish_document(DEVECO, &encoded, MAX_INDEX)
            .map_err(|error| publication(error, DEVECO))?;
        (|| {
            owner.retirement_binding(&lock)?;
            owner.retirement_index(BUNDLES, &bundles)?;
            if self.root.read(DEVECO, MAX_INDEX).map_err(unreadable)? != encoded {
                return Err(unreadable("published index changed"));
            }
            Ok(())
        })()
        .map_err(|_: WireError| unknown())?;
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt},
        path::{Path, PathBuf},
    };
    fn root() -> PathBuf {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/tool-retirement-{nonce:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        path
    }
    fn write(root: &Path, name: &str, value: &Value) -> Vec<u8> {
        let bytes = serde_json::to_vec(value).unwrap();
        fs::write(root.join(name), &bytes).unwrap();
        fs::set_permissions(root.join(name), fs::Permissions::from_mode(0o600)).unwrap();
        bytes
    }
    fn bundles(root: &Path) -> Vec<u8> {
        write(
            root,
            BUNDLES,
            &json!({"schemaVersion":"arkdeck.bootstrap-bundles/1","records":[]}),
        )
    }
    fn record(digit: &str) -> Value {
        json!({"reference":format!("tool:sha256:{}",digit.repeat(64)),"contentDigest":digit.repeat(64),
            "executableSHA256":"f".repeat(64),"byteCount":1,"registeredAt":"2026-09-11T00:00:00Z",
            "trust":{"signature":"unsigned"},"dependencies":[],"relocatable":false,
            "generation":1,"state":"available","references":[]})
    }
    fn document(records: Vec<Value>) -> Value {
        json!({"schemaVersion":"arkdeck.bootstrap-tools/2","records":records})
    }
    fn removed_deveco() -> Value {
        // Historical, explicitly unsigned metadata fixture. It is never passed as
        // successful live content or publisher evidence.
        let children=["productManifest","sdkManifest","node","hvigor","signedResourceEnvelope"].map(|role|json!({"role":role,"relativePath":"retired/path","device":1,"inode":1,"byteCount":1,"modifiedSeconds":0,"modifiedNanos":0,"changedSeconds":0,"changedNanos":0,"sha256":"0".repeat(64),"executable":false}));
        json!({"schemaVersion":"arkdeck.bootstrap-deveco-toolchains/1","records":[{"reference":format!("toolchain:sha256:{}","0".repeat(64)),"contentDigest":"0".repeat(64),"root":{"path":"/missing.app/Contents","device":1,"inode":1,"modifiedSeconds":0,"modifiedNanos":0,"changedSeconds":0,"changedNanos":0},"productVersion":"1","buildNumber":"build","sdkVersion":"1","apiVersion":"api","registeredAtUTC":"2026-09-11T00:00:00Z","bundleTrust":{"signature":"unsigned"},"children":children,"generation":2,"state":"removed","references":[]}]})
    }

    #[test]
    fn deveco_removed_receipt_requires_no_external_content_and_never_rewrites() {
        let path = root();
        let shared = bundles(&path);
        let document = removed_deveco();
        let reference = document["records"][0]["reference"].as_str().unwrap();
        let before = write(&path, DEVECO, &document);
        let owner = DevEcoRegistryStore::open_existing(&path).unwrap();
        let receipt = owner.retire(reference, "1").unwrap();
        assert_eq!(receipt["generation"], "2");
        assert_eq!(receipt["contentRetained"], false);
        assert_eq!(owner.retire(reference, "1").unwrap(), receipt);
        code(owner.retire(reference, "2"), "resourceConflict");
        code(owner.retire("bad", "2"), "invalidInput");
        assert_eq!(fs::read(path.join(DEVECO)).unwrap(), before);
        assert_eq!(fs::read(path.join(BUNDLES)).unwrap(), shared);
        let mut available = document.clone();
        available["records"][0]["state"] = json!("available");
        available["records"][0]["generation"] = json!(1);
        let before = write(&path, DEVECO, &available);
        code(owner.retire(reference, "1"), "fileIdentityChanged");
        assert_eq!(fs::read(path.join(DEVECO)).unwrap(), before);
    }
    #[test]
    fn deveco_missing_index_initializes_beside_other_family_but_not_without_shared_index() {
        let path = root();
        bundles(&path);
        fs::write(path.join("tool-retained.hdc"), b"retained").unwrap();
        code(
            DevEcoRegistryStore::open_existing(&path)
                .unwrap()
                .retire("bad", "2"),
            "invalidInput",
        );
        assert!(crate::decode_deveco_toolchains(&fs::read(path.join(DEVECO)).unwrap()).is_ok());
        let path = root();
        fs::write(path.join("retained"), b"retained").unwrap();
        code(
            DevEcoRegistryStore::open_existing(&path)
                .unwrap()
                .retire("bad", "2"),
            "recordUnreadable",
        );
        assert!(!path.join(DEVECO).exists());
    }
    fn code(result: Result<Value, WireError>, expected: &str) {
        let error = result.unwrap_err();
        assert_eq!(error.code, expected);
        assert_eq!(
            error.details.as_ref().unwrap()["phase"],
            "bootstrapRegistryOwner"
        );
        assert_eq!(error.details.as_ref().unwrap()["newDispatchCount"], 0);
    }
    #[test]
    fn shared_index_order_and_distinct_initialization_guards_are_preserved() {
        let fresh = root();
        let owner = ToolRegistryStore::open_existing(&fresh).unwrap();
        code(owner.retire("bad", "2"), "invalidInput");
        assert!(decode_bundles(&fs::read(fresh.join(BUNDLES)).unwrap()).is_ok());
        assert!(decode_tools(&fs::read(fresh.join(TOOLS)).unwrap()).is_ok());
        for name in ["tools.json", "unknown"] {
            let path = root();
            fs::write(path.join(name), b"retained").unwrap();
            code(
                ToolRegistryStore::open_existing(&path)
                    .unwrap()
                    .retire("bad", "2"),
                "recordUnreadable",
            );
            assert!(!path.join(BUNDLES).exists());
        }
        for name in [
            "tool-retained.hdc",
            ".tool-staging-retained",
            "tool-snapshots",
        ] {
            let path = root();
            let before = bundles(&path);
            fs::write(path.join(name), b"retained").unwrap();
            code(
                ToolRegistryStore::open_existing(&path)
                    .unwrap()
                    .retire("bad", "1"),
                "recordUnreadable",
            );
            assert!(!path.join(TOOLS).exists());
            assert_eq!(fs::read(path.join(BUNDLES)).unwrap(), before);
        }
        let path = root();
        bundles(&path);
        fs::write(path.join("deveco-toolchains.json"), b"other family").unwrap();
        code(
            ToolRegistryStore::open_existing(&path)
                .unwrap()
                .retire("bad", "1"),
            "invalidInput",
        );
        assert!(path.join(TOOLS).is_file());
    }
    #[test]
    fn lookup_generation_and_native_failure_order_never_modify_existing_indexes() {
        let path = root();
        let shared = bundles(&path);
        let target = record("0");
        let reference = target["reference"].as_str().unwrap().to_owned();
        let before = write(&path, TOOLS, &document(vec![target]));
        let owner = ToolRegistryStore::open_existing(&path).unwrap();
        code(owner.retire("bad", "2"), "invalidInput");
        code(
            owner.retire(&format!("tool:sha256:{}", "1".repeat(64)), "2"),
            "resourceNotFound",
        );
        for generation in ["", "0", "2", "01", "1.0", "18446744073709551615"] {
            code(owner.retire(&reference, generation), "resourceConflict");
        }
        code(owner.retire(&reference, "1"), "recordUnreadable");
        assert_eq!(fs::read(path.join(TOOLS)).unwrap(), before);
        assert_eq!(fs::read(path.join(BUNDLES)).unwrap(), shared);
        let mut invalid = document(vec![record("0")]);
        invalid["selection"] = json!({});
        write(&path, TOOLS, &invalid);
        code(owner.retire("bad", "2"), "recordUnreadable");
        let lock = owner.root.lock_document(".lock").unwrap();
        code(owner.retire("bad", "2"), "resourceConflict");
        drop(lock);
        write(
            &path,
            BUNDLES,
            &json!({"records":[],"schemaVersion":"invalid"}),
        );
        code(owner.retire("bad", "2"), "recordUnreadable");
    }
    #[test]
    fn every_reference_kind_blocks_pure_retirement_without_unpinning() {
        for kind in [
            "installation",
            "rollback",
            "controlAction",
            "job",
            "recovery",
            "agentExecution",
            "activeLease",
            "activeSelection",
            "workspacePreset",
        ] {
            let mut target = record("0");
            target["references"] = json!([{"kind":kind,"id":"test-owner"}]);
            let mut index = document(vec![target]);
            decode_tools(&serde_json::to_vec(&index).unwrap()).unwrap();
            let before = index.clone();
            assert_eq!(
                retire_record(&mut index, 0).unwrap_err().code,
                "resourceConflict"
            );
            assert_eq!(index, before);
        }
    }
    #[test]
    fn legacy_upgrade_and_selection_outcome_survive_only_the_exact_transition() {
        let mut legacy = document(vec![record("0")]);
        legacy["schemaVersion"] = json!("arkdeck.bootstrap-tools/1");
        assert!(retire_record(&mut legacy, 0).unwrap());
        assert_eq!(legacy["schemaVersion"], "arkdeck.bootstrap-tools/2");
        legacy["schemaVersion"] = json!("arkdeck.bootstrap-tools/1");
        let before = legacy.clone();
        assert!(!retire_record(&mut legacy, 0).unwrap());
        assert_eq!(legacy, before);
        let mut active = record("1");
        active["references"] = json!([{"kind":"activeSelection","id":"runtime-hdc-selection"}]);
        let mut index = document(vec![record("0"), active]);
        index["selection"] = json!({"activeToolRef":index["records"][1]["reference"],"activeGeneration":7,
            "lastOutcome":{"actionID":"action-1","result":"succeeded","oldToolRef":index["records"][0]["reference"],
                "newToolRef":index["records"][1]["reference"],"activeGeneration":7}});
        decode_tools(&serde_json::to_vec(&index).unwrap()).unwrap();
        let before = index.clone();
        assert!(retire_record(&mut index, 0).unwrap());
        decode_tools(&serde_json::to_vec(&index).unwrap()).unwrap();
        assert_eq!(index["selection"], before["selection"]);
        assert_eq!(index["records"][1], before["records"][1]);
        index["records"][0]["state"] = json!("available");
        index["records"][0]["generation"] = json!(1);
        assert_eq!(index, before);
    }
    #[test]
    fn publication_errors_distinguish_tool_io_failure_and_uncertain_outcomes() {
        code(
            Err(publication(
                DocumentPublishError::BeforePublication(io::Error::other("before")),
                TOOLS,
            )),
            "ioFailure",
        );
        code(
            Err(publication(
                DocumentPublishError::BeforePublication(io::Error::other("before")),
                BUNDLES,
            )),
            "recordUnreadable",
        );
        code(
            Err(publication(
                DocumentPublishError::OutcomeUnknown(io::Error::other("after")),
                TOOLS,
            )),
            "outcomeUnknown",
        );
    }
}
