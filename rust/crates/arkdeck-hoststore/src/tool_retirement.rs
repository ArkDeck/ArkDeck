//! Retire one unreferenced DevEco toolchain registration without deleting any
//! bytes or changing selection, reference ownership, installation, or
//! execution state, through the Bootstrap store's shared retirement binding
//! (`arkdeck_bootstrap::RetirementRoot`), as the HDC tool registry retires.
use crate::{DevEcoRegistryStore, decode_bundles};
use arkdeck_bootstrap::RetirementRoot;
use arkdeck_contract::{WireError, canonical_json};
use arkdeck_platform::DocumentPublishError;
use serde_json::{Value, json};
use std::io;
#[path = "deveco_pins.rs"]
pub(crate) mod pins;
const MAX_INDEX: usize = 4 * 1024 * 1024;
const BUNDLES: &str = "bundles.json";
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
        DocumentPublishError::BeforePublication(_) if name == DEVECO => {
            failure("ioFailure", "cannot publish host tool index")
        }
        DocumentPublishError::BeforePublication(error) => unreadable(error),
        DocumentPublishError::OutcomeUnknown(_) => unknown(),
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
}
