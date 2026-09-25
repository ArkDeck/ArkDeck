//! Metadata-only retirement of one unreferenced Bootstrap bundle. Immutable
//! content and every other record remain retained. No lifecycle or execution
//! owner is entered, and no reference can be acquired or released through here.
use crate::{BundleRegistryReadStore, decode_bundles};
use arkdeck_contract::{WireError, canonical_json};
use arkdeck_platform::{DocumentPublishError, HostReadLock};
use serde_json::{Value, json};
use std::{fs::Metadata, io, os::unix::fs::MetadataExt};

const MAX_INDEX: usize = 4 * 1024 * 1024;
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
        "bootstrap bundle registry or retained content is unreadable",
    )
}
fn publication(error: DocumentPublishError) -> WireError {
    match error {
        DocumentPublishError::BeforePublication(error) => unreadable(error),
        DocumentPublishError::OutcomeUnknown(_) => failure(
            "outcomeUnknown",
            "bundle index publication is uncertain; inspect the exact reference",
        ),
    }
}
fn same_metadata(before: &Metadata, after: &Metadata) -> bool {
    before.dev() == after.dev()
        && before.ino() == after.ino()
        && before.mode() == after.mode()
        && before.uid() == after.uid()
        && before.gid() == after.gid()
        && before.nlink() == after.nlink()
        && before.len() == after.len()
        && before.mtime() == after.mtime()
        && before.mtime_nsec() == after.mtime_nsec()
        && before.ctime() == after.ctime()
        && before.ctime_nsec() == after.ctime_nsec()
}
fn find(document: &Value, reference: &str) -> Result<usize, WireError> {
    if !reference
        .strip_prefix("bundle:sha256:")
        .is_some_and(|digest| {
            digest.len() == 64
                && digest
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
    {
        return Err(failure(
            "invalidInput",
            "expected a content-addressed daemon bundle reference",
        ));
    }
    document["records"]
        .as_array()
        .ok_or_else(|| unreadable("records"))?
        .iter()
        .position(|record| record["reference"] == reference)
        .ok_or_else(|| failure("resourceNotFound", "bundle reference does not exist"))
}
// Called only after strict decoding and fresh target-native verification.
// Its separate pure metadata step makes reference preservation directly testable
// without introducing a fake native verifier into the production owner.
fn retire_record(record: &mut Value) -> Result<bool, WireError> {
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
            "bundle is retained by an installation, rollback, pending action or Runtime owner",
        ));
    }
    record["state"] = json!("removed");
    record["generation"] = json!(2);
    Ok(true)
}
impl BundleRegistryReadStore {
    /// Retire the exact available generation. A successful retry still names
    /// expected generation `1`, revalidates native content, and returns the
    /// existing generation `2` receipt without another metadata publication.
    pub fn retire(&self, reference: &str, expected_generation: &str) -> Result<Value, WireError> {
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
        self.retirement_binding(&lock)?;
        let bytes = match self.root.read("bundles.json", MAX_INDEX) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if self.root.names(4096).map_err(unreadable)? != [".lock"] {
                    return Err(unreadable("index absent beside retained state"));
                }
                self.retirement_binding(&lock)?;
                self.root
                    .publish_document(
                        "bundles.json",
                        br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-bundles/1"}"#,
                        MAX_INDEX,
                    )
                    .map_err(publication)?;
                self.retirement_binding(&lock).map_err(|_| {
                    failure(
                        "outcomeUnknown",
                        "initial bundle index was published but its binding is uncertain",
                    )
                })?;
                self.root
                    .read("bundles.json", MAX_INDEX)
                    .map_err(unreadable)?
            }
            Err(error) => return Err(unreadable(error)),
        };
        let identity = self
            .root
            .document_metadata("bundles.json")
            .map_err(unreadable)?;
        self.retirement_index(&lock, &bytes, &identity)?;
        let decoded = decode_bundles(&bytes).map_err(unreadable)?;
        let mut document: Value = serde_json::from_slice(&decoded.document).map_err(unreadable)?;
        let position = find(&document, reference)?;
        if expected_generation != "1" {
            return Err(failure(
                "resourceConflict",
                "bundle generation does not match",
            ));
        }
        self.verify_record(&document["records"][position])
            .map_err(|error| {
                if error.kind() == io::ErrorKind::PermissionDenied {
                    failure(
                        "admissionDenied",
                        "bundle did not pass the native helper trust policy",
                    )
                } else {
                    unreadable(error)
                }
            })?;
        self.retirement_index(&lock, &bytes, &identity)?;
        if !retire_record(&mut document["records"][position])? {
            return Ok(decoded.projection[position].clone());
        }
        let encoded = canonical_json(&document).map_err(unreadable)?;
        if encoded.len() > MAX_INDEX {
            return Err(failure("quotaExceeded", "bundle index exceeds its bound"));
        }
        let updated = decode_bundles(&encoded).map_err(unreadable)?;
        self.retirement_index(&lock, &bytes, &identity)?;
        self.root
            .publish_document("bundles.json", &encoded, MAX_INDEX)
            .map_err(publication)?;
        // Publication has happened: any failed readback or changed binding now
        // has an uncertain outcome, never an invitation to repeat via fallback.
        let readback = (|| {
            self.retirement_binding(&lock)?;
            if self
                .root
                .read("bundles.json", MAX_INDEX)
                .map_err(unreadable)?
                != encoded
            {
                return Err(unreadable("published index changed"));
            }
            Ok(())
        })();
        readback.map_err(|_: WireError| failure("outcomeUnknown",
            "bundle index was published but its final binding is uncertain; inspect the exact reference"))?;
        Ok(updated.projection[position].clone())
    }
    fn retirement_binding(&self, lock: &HostReadLock) -> Result<(), WireError> {
        lock.validate_link(&self.root, ".lock")
            .map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)
    }
    fn retirement_index(
        &self,
        lock: &HostReadLock,
        bytes: &[u8],
        identity: &Metadata,
    ) -> Result<(), WireError> {
        self.retirement_binding(lock)?;
        if self
            .root
            .read("bundles.json", MAX_INDEX)
            .map_err(unreadable)?
            != bytes
            || !same_metadata(
                identity,
                &self
                    .root
                    .document_metadata("bundles.json")
                    .map_err(unreadable)?,
            )
        {
            return Err(unreadable("index changed"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt},
        path::PathBuf,
    };
    fn root() -> PathBuf {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("bundle-retirement-{nonce:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        root // Fixtures deliberately remain retained; no cleanup owner exists.
    }
    fn record() -> Value {
        json!({"reference":format!("bundle:sha256:{}", "0".repeat(64)), "digest":"0".repeat(64),
            "registeredAtUTC":"2026-09-11T00:00:00Z", "byteCount":0,"entryCount":1,
            "generation":1,"state":"available","references":[]})
    }
    fn write(root: &std::path::Path, value: &Value) -> Vec<u8> {
        let bytes = serde_json::to_vec(value).unwrap();
        fs::write(root.join("bundles.json"), &bytes).unwrap();
        fs::set_permissions(root.join("bundles.json"), fs::Permissions::from_mode(0o600)).unwrap();
        bytes
    }
    fn document(record: Value) -> Value {
        json!({"schemaVersion":"arkdeck.bootstrap-bundles/1","records":[record]})
    }
    #[test]
    fn all_nine_reference_kinds_preserve_the_record_and_retirement_is_monotonic() {
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
            let mut original = record();
            original["references"] = json!([{"kind":kind,"id":"test-owner"}]);
            decode_bundles(&serde_json::to_vec(&document(original.clone())).unwrap()).unwrap();
            let mut candidate = original.clone();
            assert_eq!(
                retire_record(&mut candidate).unwrap_err().code,
                "resourceConflict"
            );
            assert_eq!(candidate, original);
        }
        let original = record();
        let mut retired = original.clone();
        assert!(retire_record(&mut retired).unwrap());
        assert_eq!(retired["generation"], 2);
        assert_eq!(retired["state"], "removed");
        let expected = retired.clone();
        assert!(!retire_record(&mut retired).unwrap());
        assert_eq!(retired, expected);
        retired["state"] = original["state"].clone();
        retired["generation"] = original["generation"].clone();
        assert_eq!(retired, original);
    }
    #[test]
    fn strict_index_lookup_and_generation_precede_target_content_verification() {
        let root = root();
        let owner = BundleRegistryReadStore::open_existing(&root).unwrap();
        let reference = record()["reference"].as_str().unwrap().to_owned();
        let missing = format!("bundle:sha256:{}", "1".repeat(64));
        let bytes = write(&root, &document(record()));
        assert_eq!(
            owner.retire("invalid", "2").unwrap_err().code,
            "invalidInput"
        );
        assert_eq!(
            owner.retire(&missing, "2").unwrap_err().code,
            "resourceNotFound"
        );
        for generation in ["", "0", "2", "01", "1.0", "18446744073709551615"] {
            assert_eq!(
                owner.retire(&reference, generation).unwrap_err().code,
                "resourceConflict"
            );
        }
        assert_eq!(
            owner.retire(&reference, "1").unwrap_err().code,
            "recordUnreadable"
        );
        assert_eq!(fs::read(root.join("bundles.json")).unwrap(), bytes);
        let mut corrupt = document(record());
        corrupt["extra"] = json!(true);
        write(&root, &corrupt);
        assert_eq!(
            owner.retire("invalid", "2").unwrap_err().code,
            "recordUnreadable"
        );
        let lock = owner.root.lock_document(".lock").unwrap();
        assert_eq!(
            owner.retire("invalid", "2").unwrap_err().code,
            "resourceConflict"
        );
        drop(lock);
    }
    #[test]
    fn fresh_empty_owner_initializes_but_missing_index_beside_state_fails_closed() {
        let root = root();
        let owner = BundleRegistryReadStore::open_existing(&root).unwrap();
        assert_eq!(
            owner.retire("invalid", "1").unwrap_err().code,
            "invalidInput"
        );
        assert!(
            decode_bundles(&fs::read(root.join("bundles.json")).unwrap())
                .unwrap()
                .projection
                .as_array()
                .unwrap()
                .is_empty()
        );
        let other = self::root();
        fs::write(other.join("retained"), b"keep").unwrap();
        let owner = BundleRegistryReadStore::open_existing(&other).unwrap();
        assert_eq!(
            owner.retire("invalid", "1").unwrap_err().code,
            "recordUnreadable"
        );
        assert!(!other.join("bundles.json").exists());
        assert_eq!(fs::read(other.join("retained")).unwrap(), b"keep");
    }
    #[test]
    fn known_and_unknown_publication_errors_have_distinct_wire_results() {
        for (error, code) in [
            (
                DocumentPublishError::BeforePublication(io::Error::other("before")),
                "recordUnreadable",
            ),
            (
                DocumentPublishError::OutcomeUnknown(io::Error::other("after")),
                "outcomeUnknown",
            ),
        ] {
            let error = publication(error);
            assert_eq!(error.code, code);
            assert_eq!(
                error.details.as_ref().unwrap()["phase"],
                "bootstrapRegistryOwner"
            );
            assert_eq!(error.details.as_ref().unwrap()["newDispatchCount"], 0);
        }
    }

    #[test]
    #[ignore = "requires an explicit dedicated temporary native retirement registry and Swift receipt"]
    fn native_swift_and_rust_retirement_preserve_all_retained_content() {
        use std::{collections::BTreeMap, io::Write, os::unix::fs::OpenOptionsExt, path::Path};
        fn temporary(variable: &str, existing: bool) -> PathBuf {
            let path = PathBuf::from(std::env::var_os(variable).expect(variable));
            assert!(
                path.starts_with("/private/tmp")
                    || path.starts_with(std::env::temp_dir().canonicalize().unwrap())
            );
            if existing {
                assert_eq!(path.canonicalize().unwrap(), path);
            } else {
                assert_eq!(
                    path.parent().unwrap().canonicalize().unwrap(),
                    path.parent().unwrap()
                );
                assert!(fs::symlink_metadata(&path).is_err());
            }
            path
        }
        fn capture(root: &Path) -> BTreeMap<PathBuf, (Metadata, Option<String>)> {
            fn walk(
                path: &Path,
                relative: &Path,
                output: &mut BTreeMap<PathBuf, (Metadata, Option<String>)>,
            ) {
                let metadata = fs::symlink_metadata(path).unwrap();
                assert!(!metadata.file_type().is_symlink());
                let digest = if metadata.is_file() {
                    Some(arkdeck_contract::sha256_hex(&fs::read(path).unwrap()))
                } else {
                    assert!(metadata.is_dir());
                    None
                };
                if !relative.as_os_str().is_empty() {
                    output.insert(relative.into(), (metadata.clone(), digest));
                }
                if metadata.is_dir() {
                    for entry in fs::read_dir(path).unwrap() {
                        let entry = entry.unwrap();
                        walk(&entry.path(), &relative.join(entry.file_name()), output);
                    }
                }
            }
            let mut output = BTreeMap::new();
            walk(root, Path::new(""), &mut output);
            output
        }
        let root = temporary("ARKDECK_BUNDLE_RETIREMENT_NATIVE_ROOT", true);
        let swift_path = temporary("ARKDECK_BUNDLE_RETIREMENT_SWIFT_RECEIPT", true);
        let output_path = temporary("ARKDECK_BUNDLE_RETIREMENT_RUST_RECEIPT", false);
        let source: Value = serde_json::from_slice(&fs::read(swift_path).unwrap()).unwrap();
        let swift_retired = &source["swiftRetired"];
        let rust_available = &source["rustAvailable"];
        assert_eq!(swift_retired["state"], "removed");
        assert_eq!(swift_retired["generation"], "2");
        assert_eq!(rust_available["state"], "available");
        assert_eq!(rust_available["generation"], "1");
        let swift_reference = swift_retired["bundleRef"].as_str().unwrap();
        let rust_reference = rust_available["bundleRef"].as_str().unwrap();
        assert_ne!(swift_reference, rust_reference);
        let index_path = root.join("bundles.json");
        let initial_bytes = fs::read(&index_path).unwrap();
        let initial_identity = fs::metadata(&index_path).unwrap();
        let initial_document: Value = serde_json::from_slice(&initial_bytes).unwrap();
        let mut expected_document = initial_document.clone();
        let target = find(&expected_document, rust_reference).unwrap();
        assert_eq!(expected_document["records"][target]["state"], "available");
        expected_document["records"][target]["state"] = json!("removed");
        expected_document["records"][target]["generation"] = json!(2);
        let before = capture(&root);
        let root_before = fs::metadata(&root).unwrap();
        let owner = BundleRegistryReadStore::open_existing(&root).unwrap();
        assert_eq!(owner.inspect(swift_reference).unwrap(), *swift_retired);
        assert_eq!(owner.retire(swift_reference, "1").unwrap(), *swift_retired);
        assert!(same_metadata(
            &initial_identity,
            &fs::metadata(&index_path).unwrap()
        ));
        assert_eq!(fs::read(&index_path).unwrap(), initial_bytes);
        assert_eq!(owner.inspect(rust_reference).unwrap(), *rust_available);
        let retired = owner.retire(rust_reference, "1").unwrap();
        let mut expected_projection = rust_available.clone();
        expected_projection["state"] = json!("removed");
        expected_projection["generation"] = json!("2");
        assert_eq!(retired, expected_projection);
        let published_bytes = fs::read(&index_path).unwrap();
        let published_identity = fs::metadata(&index_path).unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&published_bytes).unwrap(),
            expected_document
        );
        assert_eq!(
            BundleRegistryReadStore::open_existing(&root)
                .unwrap()
                .retire(rust_reference, "1")
                .unwrap(),
            retired
        );
        assert!(same_metadata(
            &published_identity,
            &fs::metadata(&index_path).unwrap()
        ));
        assert_eq!(
            owner.retire(rust_reference, "2").unwrap_err().code,
            "resourceConflict"
        );
        assert!(same_metadata(
            &published_identity,
            &fs::metadata(&index_path).unwrap()
        ));
        assert_eq!(fs::read(&index_path).unwrap(), published_bytes);
        let after = capture(&root);
        assert_eq!(
            before.keys().collect::<Vec<_>>(),
            after.keys().collect::<Vec<_>>()
        );
        for (path, (metadata, digest)) in &before {
            if path == Path::new("bundles.json") {
                continue;
            }
            assert!(
                same_metadata(metadata, &after[path].0),
                "retained metadata changed: {path:?}"
            );
            assert_eq!(digest, &after[path].1, "retained content changed: {path:?}");
        }
        let root_after = fs::metadata(&root).unwrap();
        assert_eq!(
            (
                root_before.dev(),
                root_before.ino(),
                root_before.mode(),
                root_before.uid(),
                root_before.gid()
            ),
            (
                root_after.dev(),
                root_after.ino(),
                root_after.mode(),
                root_after.uid(),
                root_after.gid()
            )
        );
        // Receipt is the actual owner projection, with no reconstructed fields.
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&output_path)
            .unwrap();
        file.write_all(&serde_json::to_vec(&retired).unwrap())
            .unwrap();
        file.write_all(b"\n").unwrap();
        file.sync_all().unwrap();
        println!(
            "nativeBundleRetirementReceipt={}",
            json!({"bootstrapRoot":root,"bundleRef":rust_reference,"receiptPath":output_path,"deviceAcceptance":false})
        );
    }
}
