//! Frozen Bundle registration under the shared Bootstrap owner lock.
//! Immutable bytes precede their record; no helper is installed or executed.
use crate::{BundleRegistryReadStore, bundle_content::inspect_bundle_content, decode_bundles};
use arkdeck_contract::WireError;
use arkdeck_platform::{
    BootstrapBundleCapture, BootstrapBundleCaptureError, BootstrapBundlePublishError,
    DocumentPublishError, HostReadLock, inspect_bootstrap_tree,
};
use serde_json::{Value, json};
use std::{io, path::Path};

const MAX_INDEX: usize = 4 * 1024 * 1024;
const MAX_RETAINED: u64 = 2 * 1024 * 1024 * 1024;
const EMPTY: &[u8] = br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-bundles/1"}"#;
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
        "Bootstrap bundle metadata or retained content is unreadable",
    )
}
fn unknown(_: impl std::fmt::Debug) -> WireError {
    failure(
        "outcomeUnknown",
        "Bundle publication is unconfirmed; inspect before another request",
    )
}
fn captured(error: BootstrapBundleCaptureError) -> WireError {
    failure(error.code, error.message)
}
fn publication(error: DocumentPublishError) -> WireError {
    match error {
        DocumentPublishError::BeforePublication(_) => {
            failure("ioFailure", "Bootstrap metadata could not be published")
        }
        DocumentPublishError::OutcomeUnknown(_) => unknown(error),
    }
}
fn projection(bytes: &[u8], reference: &str) -> Result<Value, WireError> {
    decode_bundles(bytes)
        .map_err(unreadable)?
        .projection
        .as_array()
        .ok_or_else(|| unreadable("projection"))?
        .iter()
        .find(|row| row["bundleRef"] == reference)
        .cloned()
        .ok_or_else(|| unreadable("reference"))
}
impl BundleRegistryReadStore {
    /// Host time is supplied by the owner, never by the RPC caller. Registration
    /// holds the same lock as list, removal and the other Bootstrap families.
    pub fn register(&self, source: &Path, now: &str) -> Result<Value, WireError> {
        self.register_with_checkpoint(source, now, |_| Ok(()))
    }
    fn registration_binding(&self, lock: &HostReadLock) -> Result<(), WireError> {
        lock.validate_link(&self.root, ".lock")
            .map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)
    }
    fn registration_index(
        &self,
        lock: &HostReadLock,
        bytes: &[u8],
        identity: &std::fs::Metadata,
    ) -> Result<(), WireError> {
        self.registration_binding(lock)?;
        self.validate_index(bytes, identity).map_err(unreadable)
    }
    fn retained_bundle_bytes(&self) -> Result<u64, WireError> {
        let names = self.root.names(65_536).map_err(unreadable)?;
        if names.len() > 300 {
            return Err(failure("quotaExceeded", "Bootstrap entry bound reached"));
        }
        let mut bytes = 0u64;
        let mut interrupted = 0;
        for name in names {
            let staging = name.starts_with(".staging-");
            if !(staging || name.starts_with("bundle-") && name.ends_with(".app")) {
                continue;
            }
            if staging {
                interrupted += 1;
            }
            if interrupted >= 4 {
                return Err(failure(
                    "quotaExceeded",
                    "interrupted Bundle captures require inspection",
                ));
            }
            let held = self.root.child(&name).map_err(unreadable)?;
            let path = self.path.join(&name);
            let tree = inspect_bootstrap_tree(&path).map_err(unreadable)?;
            held.validate_path(&path).map_err(unreadable)?;
            bytes = bytes
                .checked_add(tree.byte_count)
                .ok_or_else(|| unreadable("byte overflow"))?;
            if bytes > MAX_RETAINED {
                return Err(failure(
                    "quotaExceeded",
                    "retained Bundle content exceeds its quota",
                ));
            }
        }
        Ok(bytes)
    }
    fn register_with_checkpoint(
        &self,
        source: &Path,
        now: &str,
        checkpoint: impl Fn(&str) -> io::Result<()>,
    ) -> Result<Value, WireError> {
        let text = source
            .to_str()
            .ok_or_else(|| failure("invalidInput", "a local Bundle is required"))?;
        if !text.starts_with('/')
            || text.len() > 16_384
            || text.contains('\0')
            || text.split('/').any(|part| matches!(part, "." | ".."))
            || source.extension().and_then(|v| v.to_str()) != Some("app")
            || arkdeck_platform::host_legacy_iso8601(now) != Some(true)
        {
            return Err(failure(
                "invalidInput",
                "the local Bundle or host timestamp is invalid",
            ));
        }
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let lock = self.root.lock_document(".lock").map_err(|error| {
            if error.kind() == io::ErrorKind::WouldBlock {
                failure(
                    "resourceConflict",
                    "another Bootstrap operation holds the store",
                )
            } else {
                unreadable(error)
            }
        })?;
        let bytes = match self.root.read("bundles.json", MAX_INDEX) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if self
                    .root
                    .names(65_536)
                    .map_err(unreadable)?
                    .iter()
                    .any(|name| name != ".lock")
                {
                    return Err(unreadable("missing index beside retained state"));
                }
                self.registration_binding(&lock)?;
                self.root
                    .publish_document("bundles.json", EMPTY, MAX_INDEX)
                    .map_err(publication)?;
                EMPTY.to_vec()
            }
            Err(error) => return Err(unreadable(error)),
        };
        let identity = self
            .root
            .document_metadata("bundles.json")
            .map_err(unreadable)?;
        let decoded = decode_bundles(&bytes).map_err(unreadable)?;
        let mut index: Value = serde_json::from_slice(&decoded.document).map_err(unreadable)?;
        let retained = self.retained_bundle_bytes()?;
        let mut stage = BootstrapBundleCapture::capture(&self.path, source).map_err(captured)?;
        checkpoint("copied").map_err(unreadable)?;
        stage.revalidate_sources().map_err(captured)?;
        let content = inspect_bundle_content(stage.path()).map_err(|error| {
            if error.kind() == io::ErrorKind::PermissionDenied {
                failure(
                    "admissionDenied",
                    "captured Bundle failed its native trust policy",
                )
            } else {
                failure(
                    "fileIdentityChanged",
                    "captured Bundle changed during native verification",
                )
            }
        })?;
        stage.revalidate_sources().map_err(captured)?;
        let reference = format!("bundle:sha256:{}", content.digest);
        if let Some(old) = index["records"]
            .as_array()
            .ok_or_else(|| unreadable("records"))?
            .iter()
            .find(|row| row["reference"] == reference)
        {
            if old["state"] != "available" {
                return Err(failure(
                    "resourceConflict",
                    "this exact Bundle was removed; historical content remains retained",
                ));
            }
            self.verify_record(old).map_err(unreadable)?;
            self.registration_index(&lock, &bytes, &identity)?;
            return projection(&bytes, &reference);
        }
        let mut record = json!({"reference":reference,"digest":content.digest,"registeredAtUTC":now,
            "version":content.version,"byteCount":content.byte_count,"entryCount":content.entry_count,
            "generation":1,"state":"available","references":[]});
        record
            .as_object_mut()
            .expect("object")
            .retain(|_, v| !v.is_null());
        let name = format!("bundle-{}.app", content.digest);
        let exists = match self.root.child(&name) {
            Ok(_) => {
                self.verify_record(&record).map_err(unreadable)?;
                true
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => false,
            Err(error) => return Err(unreadable(error)),
        };
        if index["records"]
            .as_array()
            .ok_or_else(|| unreadable("records"))?
            .len()
            >= 128
            || retained > MAX_RETAINED - if exists { 0 } else { content.byte_count }
        {
            return Err(failure(
                "quotaExceeded",
                "registered Bundle content exceeds the Bootstrap quota",
            ));
        }
        let records = index["records"]
            .as_array_mut()
            .ok_or_else(|| unreadable("records"))?;
        records.push(record.clone());
        records.sort_by(|a, b| a["reference"].as_str().cmp(&b["reference"].as_str()));
        let encoded = serde_json::to_vec(&index).map_err(unreadable)?;
        if encoded.len() > MAX_INDEX {
            return Err(failure(
                "quotaExceeded",
                "Bundle index exceeds its storage bound",
            ));
        }
        let document = decode_bundles(&encoded).map_err(unreadable)?.document;
        let result = projection(&document, &reference)?;
        self.registration_index(&lock, &bytes, &identity)?;
        checkpoint("beforeContentPublication").map_err(unreadable)?;
        self.registration_index(&lock, &bytes, &identity)?;
        stage.revalidate_sources().map_err(captured)?;
        stage
            .publish(&content.digest)
            .map_err(|error| match error {
                BootstrapBundlePublishError::BeforePublication(error) => captured(error),
                BootstrapBundlePublishError::OutcomeUnknown(error) => unknown(error),
            })?;
        // Both exclusive publication and an existing orphan require fresh native
        // readback before the receipt. Never overwrite or remove retained bytes.
        checkpoint("contentPublished").map_err(unknown)?;
        self.verify_record(&record).map_err(unknown)?;
        self.registration_index(&lock, &bytes, &identity)
            .map_err(unknown)?;
        self.root
            .publish_document("bundles.json", &document, MAX_INDEX)
            .map_err(unknown)?;
        if checkpoint("recordPublished").is_err()
            || self.registration_binding(&lock).is_err()
            || self.root.read("bundles.json", MAX_INDEX).ok().as_deref()
                != Some(document.as_slice())
        {
            return Err(unknown("published receipt interrupted"));
        }
        Ok(result)
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
    const NOW: &str = "2026-09-12T00:00:00Z";
    fn root() -> PathBuf {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("bundle-registration-{nonce:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        path
    }
    fn write(root: &Path, name: &str, bytes: &[u8]) {
        fs::write(root.join(name), bytes).unwrap();
        fs::set_permissions(root.join(name), fs::Permissions::from_mode(0o600)).unwrap();
    }
    #[test]
    fn invalid_inputs_do_not_initialize_and_retained_state_is_never_healed() {
        let root = root();
        let store = BundleRegistryReadStore::open_existing(&root).unwrap();
        for source in ["relative.app", "/tmp/../Source.app", "/tmp/not-bundle"] {
            assert_eq!(
                store.register(Path::new(source), NOW).unwrap_err().code,
                "invalidInput"
            );
        }
        assert_eq!(fs::read_dir(&root).unwrap().count(), 0);
        write(&root, "retained", b"keep");
        assert_eq!(
            store
                .register(Path::new("/missing.app"), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert!(!root.join("bundles.json").exists());
        assert_eq!(fs::read(root.join("retained")).unwrap(), b"keep");
    }
    #[test]
    fn corrupt_indexes_staging_quota_and_lock_fail_before_capture() {
        let root = root();
        let store = BundleRegistryReadStore::open_existing(&root).unwrap();
        write(&root, "bundles.json", b"{broken");
        assert_eq!(
            store
                .register(Path::new("/missing.app"), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        write(&root, "bundles.json", EMPTY);
        for n in 0..4 {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(root.join(format!(".staging-retained-{n}")))
                .unwrap();
        }
        assert_eq!(
            store
                .register(Path::new("/missing.app"), NOW)
                .unwrap_err()
                .code,
            "quotaExceeded"
        );
        let lock = store.root.lock_document(".lock").unwrap();
        assert_eq!(
            store
                .register(Path::new("/missing.app"), NOW)
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        drop(lock);
        assert_eq!(fs::read(root.join("bundles.json")).unwrap(), EMPTY);
        assert_eq!(fs::read_dir(root).unwrap().count(), 6);
    }
    #[test]
    fn unsigned_bundle_leaves_only_empty_index_and_preserves_source() {
        let source_root = root();
        let source = source_root.join("Unsigned.app");
        fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(source.join("Contents"))
            .unwrap();
        write(&source.join("Contents"), "Info.plist", br#"<plist><dict><key>CFBundleIdentifier</key><string>com.arkdeck.agentd</string><key>CFBundleExecutable</key><string>arkdeck-agentd</string></dict></plist>"#);
        fs::DirBuilder::new()
            .mode(0o700)
            .create(source.join("Contents/MacOS"))
            .unwrap();
        write(
            &source.join("Contents/MacOS"),
            "arkdeck-agentd",
            b"unsigned fixture bytes",
        );
        fs::set_permissions(
            source.join("Contents/MacOS/arkdeck-agentd"),
            fs::Permissions::from_mode(0o700),
        )
        .unwrap();
        let root = root();
        let store = BundleRegistryReadStore::open_existing(&root).unwrap();
        assert_eq!(
            store.register(&source, NOW).unwrap_err().code,
            "admissionDenied"
        );
        assert_eq!(fs::read(root.join("bundles.json")).unwrap(), EMPTY);
        assert_eq!(fs::read_dir(root).unwrap().count(), 2);
        assert!(source.join("Contents/Info.plist").is_file());
    }
}
