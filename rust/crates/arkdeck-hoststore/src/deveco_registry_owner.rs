//! Owner of DevEco registration metadata. Available records require
//! fresh external content verification; removed records are historical metadata
//! and deliberately do not require externally retained content (Swift parity).
use crate::{
    decode_bundles, deveco_content,
    deveco_registry::{digest, read_index},
};
use arkdeck_contract::WireError;
use arkdeck_platform::{DocumentPublishError, HostDirectory, HostReadLock};
use serde_json::{Value, json};
use std::{
    io,
    path::{Path, PathBuf},
};
const MAX_INDEX: usize = 4 * 1024 * 1024;
const DOCUMENT: &str = "deveco-toolchains.json";
const EMPTY_BUNDLES: &[u8] = b"{\"records\":[],\"schemaVersion\":\"arkdeck.bootstrap-bundles/1\"}";
const EMPTY_DEVECO: &[u8] =
    b"{\"records\":[],\"schemaVersion\":\"arkdeck.bootstrap-deveco-toolchains/1\"}";
pub struct DevEcoRegistryStore {
    root: HostDirectory,
    path: PathBuf,
}
fn corrupt() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "DevEco index failed schema or identity validation",
    )
}
fn read_error(error: io::Error) -> io::Error {
    if matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::PermissionDenied
    ) {
        error
    } else {
        corrupt()
    }
}
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
        "Bootstrap metadata or identity is unreadable",
    )
}
fn native_registration_error(error: io::Error) -> WireError {
    match error.kind() {
        io::ErrorKind::PermissionDenied => failure(
            "admissionDenied",
            "DevEco content failed its native trust policy",
        ),
        io::ErrorKind::InvalidData | io::ErrorKind::NotFound => failure(
            "fileIdentityChanged",
            "DevEco source cannot be read under its required identity",
        ),
        _ => failure("ioFailure", "DevEco source inspection could not complete"),
    }
}
fn publication(error: DocumentPublishError) -> WireError {
    match error {
        DocumentPublishError::BeforePublication(_) => failure(
            "ioFailure",
            "DevEco metadata transaction could not be written",
        ),
        DocumentPublishError::OutcomeUnknown(_) => failure(
            "outcomeUnknown",
            "DevEco metadata publication is unconfirmed; inspect before another request",
        ),
    }
}
impl DevEcoRegistryStore {
    pub fn open_existing(path: &Path) -> io::Result<Self> {
        Ok(Self {
            root: HostDirectory::open(path)?,
            path: path.into(),
        })
    }
    pub fn list(&self) -> io::Result<Vec<Value>> {
        self.read(None).map_err(read_error)
    }
    pub fn inspect(&self, reference: &str) -> io::Result<Value> {
        if !reference
            .strip_prefix("toolchain:sha256:")
            .is_some_and(digest)
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "exact content-addressed toolchain reference is required",
            ));
        }
        self.read(Some(reference))
            .map_err(read_error)?
            .into_iter()
            .next()
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    "toolchain reference does not exist",
                )
            })
    }
    /// Registers measured local content without copying, selecting or executing
    /// it. The composition root supplies its clock; no wire timestamp is accepted.
    pub fn register(&self, source: &Path, now: &str) -> Result<Value, WireError> {
        self.register_with_checkpoint(source, now, |_| Ok(()))
    }

    fn register_with_checkpoint(
        &self,
        source: &Path,
        now: &str,
        checkpoint: impl Fn(&str) -> io::Result<()>,
    ) -> Result<Value, WireError> {
        let text = source
            .to_str()
            .ok_or_else(|| failure("invalidInput", "a local root is required"))?;
        if !text.starts_with('/')
            || text.as_bytes().contains(&0)
            || text.split('/').any(|part| matches!(part, "." | ".."))
            || arkdeck_platform::host_legacy_iso8601(now) != Some(true)
        {
            return Err(failure(
                "invalidInput",
                "the local root or host timestamp is invalid",
            ));
        }
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
        let bundles = match self.root.read("bundles.json", MAX_INDEX) {
            Ok(bytes) => {
                decode_bundles(&bytes).map_err(unreadable)?;
                bytes
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if self
                    .root
                    .names(65_536)
                    .map_err(unreadable)?
                    .iter()
                    .any(|name| name != ".lock")
                {
                    return Err(failure(
                        "recordUnreadable",
                        "bundle index is missing beside retained state",
                    ));
                }
                self.check_identity(&lock)?;
                self.root
                    .publish_document("bundles.json", EMPTY_BUNDLES, MAX_INDEX)
                    .map_err(publication)?;
                EMPTY_BUNDLES.to_vec()
            }
            Err(error) => return Err(unreadable(error)),
        };
        let bytes = match self.root.read(DOCUMENT, MAX_INDEX) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                self.check_identity(&lock)?;
                self.root
                    .publish_document(DOCUMENT, EMPTY_DEVECO, MAX_INDEX)
                    .map_err(publication)?;
                EMPTY_DEVECO.to_vec()
            }
            Err(error) => return Err(unreadable(error)),
        };
        let (mut index, _) = read_index(&bytes).map_err(unreadable)?;
        // Foundation's file URL removes a trailing directory slash but retains
        // internal double slashes. The latter remain part of the stored identity
        // and can conflict with an existing registration of the same content.
        let source = Path::new(text.trim_end_matches('/'));
        if source.file_name().is_none_or(|name| name != "Contents")
            || source
                .parent()
                .and_then(Path::extension)
                .is_none_or(|extension| extension != "app")
        {
            return Err(failure(
                "invalidInput",
                "DevEco registration requires the app's Contents root",
            ));
        }
        let mut measured =
            deveco_content::inspect_root(source).map_err(native_registration_error)?;
        let existing = index
            .records
            .iter()
            .find(|record| record.reference == measured.reference);
        let result = if let Some(existing) = existing {
            if existing.state != "available" || existing.root != measured.root {
                return Err(failure(
                    "resourceConflict",
                    "this DevEco content is retired or registered from another root",
                ));
            }
            let remeasured =
                deveco_content::inspect_root(source).map_err(native_registration_error)?;
            if !deveco_content::matches_record(existing, &remeasured) {
                return Err(unreadable("registered DevEco content changed"));
            }
            existing.value()
        } else {
            if index.records.len() >= 32 {
                return Err(failure(
                    "quotaExceeded",
                    "DevEco registration limit is reached",
                ));
            }
            measured.registered_at = now.into();
            measured.value()
        };
        checkpoint("beforePublication").map_err(unreadable)?;
        self.check_identity(&lock)?;
        if self
            .root
            .read("bundles.json", MAX_INDEX)
            .map_err(unreadable)?
            != bundles
            || self.root.read(DOCUMENT, MAX_INDEX).map_err(unreadable)? != bytes
        {
            return Err(unreadable(
                "metadata changed while inspecting local content",
            ));
        }
        if existing.is_none() {
            index.records.push(measured);
            index.records.sort_by(|a, b| a.reference.cmp(&b.reference));
            let encoded = serde_json::to_vec(&index).map_err(unreadable)?;
            if encoded.len() > MAX_INDEX {
                return Err(failure(
                    "quotaExceeded",
                    "DevEco index exceeds its storage bound",
                ));
            }
            let (_, document) = read_index(&encoded).map_err(unreadable)?;
            self.root
                .publish_document(DOCUMENT, &document, MAX_INDEX)
                .map_err(publication)?;
            // Once renamed, an interrupted receipt must not be treated as proof
            // that no metadata was written. An independent inspect reconciles it.
            if checkpoint("afterPublication").is_err()
                || self.check_identity(&lock).is_err()
                || self.root.read(DOCUMENT, MAX_INDEX).ok().as_deref() != Some(document.as_slice())
            {
                return Err(failure(
                    "outcomeUnknown",
                    "DevEco metadata receipt was interrupted; inspect before another request",
                ));
            }
        }
        Ok(result)
    }

    fn check_identity(&self, lock: &HostReadLock) -> Result<(), WireError> {
        lock.validate_link(&self.root, ".lock")
            .map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)
    }
    fn read(&self, reference: Option<&str>) -> io::Result<Vec<Value>> {
        self.root.validate_path(&self.path).map_err(|_| corrupt())?;
        let lock = self
            .root
            .try_lock_existing_strict(".lock")
            .map_err(|_| corrupt())?
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "bootstrap owner lock unavailable",
                )
            })?;
        // withSharedStore validates the existing bundle index before reading any
        // other resource family. No empty index is synthesized or written.
        let bundles = self
            .root
            .read("bundles.json", MAX_INDEX)
            .map_err(|_| corrupt())?;
        decode_bundles(&bundles).map_err(|_| corrupt())?;
        let bytes = self
            .root
            .read("deveco-toolchains.json", MAX_INDEX)
            .map_err(|_| corrupt())?;
        let (index, _) = read_index(&bytes).map_err(|_| corrupt())?;
        let mut values = Vec::new();
        for record in &index.records {
            if reference.is_some_and(|r| r != record.reference) {
                continue;
            }
            if record.state == "available" {
                deveco_content::verify(record)?;
            }
            values.push(record.value());
        }
        if self
            .root
            .read("deveco-toolchains.json", MAX_INDEX)
            .map_err(|_| corrupt())?
            != bytes
            || self
                .root
                .read("bundles.json", MAX_INDEX)
                .map_err(|_| corrupt())?
                != bundles
        {
            return Err(corrupt());
        }
        lock.validate_link(&self.root, ".lock")
            .map_err(|_| corrupt())?;
        self.root.validate_path(&self.path).map_err(|_| corrupt())?;
        Ok(values)
    }
}

#[cfg(test)]
mod registration_tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt},
    };

    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
            let path = PathBuf::from(format!("/private/tmp/deveco-registration-{nonce:032x}"));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self(path)
        }
        fn write(&self, name: &str, bytes: &[u8]) {
            fs::write(self.0.join(name), bytes).unwrap();
            fs::set_permissions(self.0.join(name), fs::Permissions::from_mode(0o600)).unwrap();
        }
        fn store(&self) -> DevEcoRegistryStore {
            DevEcoRegistryStore::open_existing(&self.0).unwrap()
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    const NOW: &str = "2026-09-11T00:00:00Z";

    #[test]
    fn registration_initialization_preserves_corruption_and_other_family_state() {
        let root = Root::new();
        let store = root.store();
        assert_eq!(
            store.register(Path::new("relative"), NOW).unwrap_err().code,
            "invalidInput"
        );
        assert_eq!(fs::read_dir(&root.0).unwrap().count(), 0);
        root.write("untracked", b"retained content");
        assert_eq!(
            store
                .register(Path::new("/missing.app/Contents"), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert!(!root.0.join("bundles.json").exists());
        assert!(!root.0.join(DOCUMENT).exists());
        assert_eq!(
            fs::read(root.0.join("untracked")).unwrap(),
            b"retained content"
        );

        let corrupt_root = Root::new();
        corrupt_root.write("bundles.json", b"damaged");
        assert_eq!(
            corrupt_root
                .store()
                .register(Path::new("/missing.app/Contents"), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert_eq!(
            fs::read(corrupt_root.0.join("bundles.json")).unwrap(),
            b"damaged"
        );
        assert!(!corrupt_root.0.join(DOCUMENT).exists());

        let fresh = Root::new();
        assert_eq!(
            fresh
                .store()
                .register(Path::new("/invalid-root"), NOW)
                .unwrap_err()
                .code,
            "invalidInput"
        );
        assert_eq!(
            fs::read(fresh.0.join("bundles.json")).unwrap(),
            EMPTY_BUNDLES
        );
        assert_eq!(fs::read(fresh.0.join(DOCUMENT)).unwrap(), EMPTY_DEVECO);
        assert_eq!(
            fresh
                .store()
                .register(Path::new("/missing.app/Contents"), NOW)
                .unwrap_err()
                .code,
            "fileIdentityChanged"
        );
        assert_eq!(fs::read(fresh.0.join(DOCUMENT)).unwrap(), EMPTY_DEVECO);
        fresh.write(DOCUMENT, b"damaged");
        assert_eq!(
            fresh
                .store()
                .register(Path::new("/missing.app/Contents"), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert_eq!(fs::read(fresh.0.join(DOCUMENT)).unwrap(), b"damaged");
    }

    #[test]
    fn registration_obeys_shared_lock_and_refuses_unsafe_index_without_rewrite() {
        let root = Root::new();
        let store = root.store();
        let held = HostDirectory::open(&root.0).unwrap();
        let lock = held.lock_document(".lock").unwrap();
        assert_eq!(
            store
                .register(Path::new("/missing.app/Contents"), NOW)
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        assert_eq!(held.names(10).unwrap(), vec![".lock"]);
        drop(lock);
        root.write("bundles.json", EMPTY_BUNDLES);
        let outside = Root::new();
        outside.write("index", EMPTY_DEVECO);
        std::os::unix::fs::symlink(outside.0.join("index"), root.0.join(DOCUMENT)).unwrap();
        assert_eq!(
            store
                .register(Path::new("/missing.app/Contents"), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert!(
            fs::symlink_metadata(root.0.join(DOCUMENT))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(fs::read(outside.0.join("index")).unwrap(), EMPTY_DEVECO);
    }

    #[test]
    #[ignore = "requires ARKDECK_DEVECO_SOURCE_ROOT pointing to an actual signed DevEco Contents root"]
    fn native_registration_reopens_idempotently_and_preserves_uncertain_publication() {
        let source = PathBuf::from(
            std::env::var_os("ARKDECK_DEVECO_SOURCE_ROOT").expect("actual DevEco root"),
        );
        let measured = deveco_content::inspect_root(&source).unwrap();
        let root = Root::new();
        let store = root.store();
        let result = store.register(&source, NOW).unwrap();
        assert_eq!(result, measured.value());
        let bytes = fs::read(root.0.join(DOCUMENT)).unwrap();
        let (index, document) = read_index(&bytes).unwrap();
        assert_eq!(document, bytes);
        assert_eq!(index.records[0].registered_at, NOW);
        assert_eq!(index.records[0].root, measured.root);
        assert_eq!(
            store.register(&source, "2026-09-12T00:00:00Z").unwrap(),
            result
        );
        assert_eq!(fs::read(root.0.join(DOCUMENT)).unwrap(), bytes);
        assert_eq!(
            store
                .register(Path::new(&format!("{}/", source.display())), NOW)
                .unwrap(),
            result
        );
        let double_slash = source
            .to_str()
            .unwrap()
            .replacen("/Contents", "//Contents", 1);
        assert_eq!(
            store
                .register(Path::new(&double_slash), NOW)
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        assert_eq!(fs::read(root.0.join(DOCUMENT)).unwrap(), bytes);
        assert_eq!(
            root.store()
                .inspect(result["toolRef"].as_str().unwrap())
                .unwrap(),
            result
        );
        assert_eq!(deveco_content::inspect_root(&source).unwrap(), measured);

        let interrupted = Root::new();
        let error = interrupted
            .store()
            .register_with_checkpoint(&source, NOW, |phase| {
                if phase == "afterPublication" {
                    Err(io::Error::other("receipt interrupted"))
                } else {
                    Ok(())
                }
            })
            .unwrap_err();
        assert_eq!(error.code, "outcomeUnknown");
        assert_eq!(
            interrupted
                .store()
                .inspect(result["toolRef"].as_str().unwrap())
                .unwrap(),
            result
        );
        let committed = fs::read(interrupted.0.join(DOCUMENT)).unwrap();
        assert_eq!(
            interrupted
                .store()
                .register(&source, "2026-09-12T00:00:00Z")
                .unwrap(),
            result
        );
        assert_eq!(fs::read(interrupted.0.join(DOCUMENT)).unwrap(), committed);

        let changed = Root::new();
        let error = changed
            .store()
            .register_with_checkpoint(&source, NOW, |phase| {
                if phase == "beforePublication" {
                    changed.write(DOCUMENT, b"changed externally");
                }
                Ok(())
            })
            .unwrap_err();
        assert_eq!(error.code, "recordUnreadable");
        assert_eq!(
            fs::read(changed.0.join(DOCUMENT)).unwrap(),
            b"changed externally"
        );

        let mut retired: Value = serde_json::from_slice(&bytes).unwrap();
        retired["records"][0]["state"] = json!("removed");
        retired["records"][0]["generation"] = json!(2);
        root.write(DOCUMENT, &serde_json::to_vec(&retired).unwrap());
        let before = fs::read(root.0.join(DOCUMENT)).unwrap();
        assert_eq!(
            store.register(&source, NOW).unwrap_err().code,
            "resourceConflict"
        );
        assert_eq!(fs::read(root.0.join(DOCUMENT)).unwrap(), before);
    }

    #[test]
    #[ignore = "requires ARKDECK_DEVECO_SOURCE_ROOT pointing to an actual signed DevEco Contents root"]
    fn native_registration_preserves_a_full_historical_index() {
        let source = PathBuf::from(
            std::env::var_os("ARKDECK_DEVECO_SOURCE_ROOT").expect("actual DevEco root"),
        );
        let measured = deveco_content::inspect_root(&source).unwrap();
        // Synthetic removed metadata exercises the retained-record quota. These
        // records never represent available native content or hardware evidence.
        let records: Vec<_> = (0..32)
            .map(|ordinal| {
                let mut record = measured.clone();
                record.content_digest = format!("{ordinal:064x}");
                record.reference = format!("toolchain:sha256:{}", record.content_digest);
                record.state = "removed".into();
                record.generation = 2;
                record
            })
            .collect();
        let bytes = serde_json::to_vec(
            &json!({"schemaVersion":"arkdeck.bootstrap-deveco-toolchains/1","records":records}),
        )
        .unwrap();
        read_index(&bytes).unwrap();
        let root = Root::new();
        root.write("bundles.json", EMPTY_BUNDLES);
        root.write(DOCUMENT, &bytes);
        assert_eq!(
            root.store().register(&source, NOW).unwrap_err().code,
            "quotaExceeded"
        );
        assert_eq!(fs::read(root.0.join(DOCUMENT)).unwrap(), bytes);
    }
}
