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
    pub(crate) root: HostDirectory,
    pub(crate) path: PathBuf,
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
/// A registration source as this host spells a local root: `/…` without a
/// `.` or `..` component on macOS; a standard `X:\…` path on Windows (the
/// spelling on disk is then checked by the reader, which also refuses any
/// link, junction or other layout).
#[cfg(not(windows))]
fn host_root_text(text: &str) -> bool {
    text.starts_with('/')
        && !text.as_bytes().contains(&0)
        && !text.split('/').any(|part| matches!(part, "." | ".."))
}
#[cfg(windows)]
fn host_root_text(text: &str) -> bool {
    !text.as_bytes().contains(&0)
        && super::deveco_registry::host_root_path(text.trim_end_matches('\\'))
}

/// macOS: the app's `Contents` root. Foundation's file URL removes a trailing
/// directory slash but retains internal double slashes; the latter remain
/// part of the stored identity and can conflict with an existing
/// registration of the same content.
#[cfg(not(windows))]
fn host_source(text: &str) -> Result<&Path, WireError> {
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
    Ok(source)
}

/// Windows: the DevEco Studio directory itself (it must hold the Windows
/// launcher; the reader refuses anything else).
#[cfg(windows)]
fn host_source(text: &str) -> Result<&Path, WireError> {
    Ok(Path::new(text.trim_end_matches('\\')))
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
        if !host_root_text(text) || arkdeck_platform::host_legacy_iso8601(now) != Some(true) {
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
        let source = host_source(text)?;
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

#[cfg(all(test, target_os = "macos"))]
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

/// The Windows registration (TASK-XPA-011) over a fixture DevEco Studio
/// directory under the account's local application data: the launcher and
/// node are copies of system executables signed with the host's development
/// signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`), the fixture's stand-in for the
/// DevEco publisher and the OpenJS Foundation; the signed cases are skipped,
/// saying so, where the host has no such signer. Nothing is run.
#[cfg(all(test, windows))]
mod windows_registration_tests {
    use super::*;
    use crate::deveco_content::TEST_PUBLISHER;
    use arkdeck_platform::{create_private_directory, create_private_file};
    use std::fs;
    use std::io::Write;

    const NOW: &str = "2026-09-30T00:00:00Z";
    const PRODUCT: &str = r#"{"name":"DevEco Studio","version":"6.0.0.868","buildNumber":"DS-253.1.2","productCode":"DS","productVendor":"Huawei","dataDirectoryName":"fixture","launch":[{"os":"Windows","arch":"amd64","launcherPath":"bin/devecostudio64.exe"}]}"#;
    const SDK: &str = r#"{"meta":{"version":"1.0.0"},"data":{"apiVersion":"26","displayName":"fixture","platformVersion":"6.0.0","version":"6.0.0.43"}}"#;
    const DEVELOPMENT_SIGNER: &str = "ArkDeck Development Daemon (host-trusted only)";

    struct Scratch(PathBuf);
    impl Scratch {
        fn new(label: &str) -> Self {
            let base = arkdeck_platform::application_support_directory()
                .unwrap()
                .canonicalize()
                .unwrap();
            let base = base.to_str().unwrap();
            let path = PathBuf::from(base.strip_prefix(r"\\?\").unwrap_or(base)).join(format!(
                "arkdeck-test-{label}-{:032x}",
                u128::from_le_bytes(arkdeck_platform::random_bytes().unwrap())
            ));
            create_private_directory(&path).unwrap();
            Self(path)
        }
        fn directories(&self, relative: &str) -> PathBuf {
            let mut path = self.0.clone();
            for part in relative.split('\\') {
                path.push(part);
                if !path.exists() {
                    create_private_directory(&path).unwrap();
                }
            }
            path
        }
        fn file(&self, relative: &str, bytes: &[u8]) -> PathBuf {
            let (parent, _) = relative.rsplit_once('\\').unwrap();
            let path = self
                .directories(parent)
                .join(relative.rsplit_once('\\').unwrap().1);
            let _ = fs::remove_file(&path);
            create_private_file(&path)
                .unwrap()
                .write_all(bytes)
                .unwrap();
            path
        }
        /// `System32\<system>` copied to `relative`, signed when `sign`.
        fn executable(&self, relative: &str, system: &str, sign: bool) -> bool {
            let source = PathBuf::from(std::env::var_os("SystemRoot").unwrap())
                .join("System32")
                .join(system);
            let path = self.file(relative, &fs::read(source).unwrap());
            !sign || sign_file(&path)
        }
        /// A DevEco Studio directory in the Windows layout.
        fn deveco(&self, sign_node: bool) -> Option<PathBuf> {
            if !self.executable(r"DevEco Studio\bin\devecostudio64.exe", "whoami.exe", true)
                || !self.executable(
                    r"DevEco Studio\tools\node\node.exe",
                    "hostname.exe",
                    sign_node,
                )
                || !self.executable(r"DevEco Studio\jbr\bin\java.exe", "where.exe", true)
            {
                return None;
            }
            self.file(r"DevEco Studio\product-info.json", PRODUCT.as_bytes());
            self.file(r"DevEco Studio\sdk\default\sdk-pkg.json", SDK.as_bytes());
            self.directories(r"DevEco Studio\sdk\default\openharmony");
            self.file(
                r"DevEco Studio\tools\hvigor\bin\hvigorw.js",
                b"// fixture hvigor wrapper; never run\n",
            );
            Some(self.0.join("DevEco Studio"))
        }
        fn store(&self) -> DevEcoRegistryStore {
            DevEcoRegistryStore::open_existing(&self.directories("bootstrap")).unwrap()
        }
        fn index(&self) -> Vec<u8> {
            fs::read(self.0.join("bootstrap").join(DOCUMENT)).unwrap()
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn sign_file(path: &Path) -> bool {
        let Some(thumbprint) = std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT") else {
            eprintln!("ARKDECK_DEV_SIGNER_THUMBPRINT is not set; the signed path is not exercised");
            return false;
        };
        let script = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../scripts/windows-dev-identity.ps1");
        let alias = std::env::var_os("LOCALAPPDATA")
            .map(|local| PathBuf::from(local).join(r"Microsoft\WindowsApps\pwsh.exe"))
            .filter(|alias| alias.exists());
        let pwsh = std::env::var_os("PATH")
            .and_then(|paths| {
                std::env::split_paths(&paths)
                    .map(|directory| directory.join("pwsh.exe"))
                    .find(|candidate| candidate.is_file())
            })
            .or(alias)
            .expect("PowerShell 7 signs the fixture executables");
        let output = std::process::Command::new(pwsh)
            .args(["-NoProfile", "-NonInteractive", "-File"])
            .arg(&script)
            .arg("sign")
            .arg("-Thumbprint")
            .arg(&thumbprint)
            .arg("-Path")
            .arg(path)
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        true
    }

    /// The development signer stands in for the DevEco publisher.
    struct Publisher;
    impl Publisher {
        fn development() -> Self {
            TEST_PUBLISHER
                .with(|publisher| *publisher.borrow_mut() = Some(DEVELOPMENT_SIGNER.into()));
            Self
        }
    }
    impl Drop for Publisher {
        fn drop(&mut self) {
            TEST_PUBLISHER.with(|publisher| *publisher.borrow_mut() = None);
        }
    }

    #[test]
    fn node_and_hvigor_register_as_one_windows_toolchain_reference() {
        let scratch = Scratch::new("deveco-registration");
        let Some(root) = scratch.deveco(true) else {
            return;
        };
        let _publisher = Publisher::development();
        let store = scratch.store();
        let value = store.register(&root, NOW).unwrap();
        let reference = value["toolRef"].as_str().unwrap().to_owned();
        assert!(reference.starts_with("toolchain:sha256:"), "{value}");
        assert_eq!(value["kind"], "deveco");
        assert_eq!(value["platform"], "windows");
        assert_eq!(
            value["contentSchemaVersion"],
            "arkdeck.deveco-toolchain-content/2"
        );
        assert_eq!(value["productVersion"], "6.0.0.868");
        assert_eq!(value["apiVersion"], "26");
        let children = value["childTools"].as_array().unwrap();
        let roles: Vec<&str> = children
            .iter()
            .map(|c| c["role"].as_str().unwrap())
            .collect();
        assert_eq!(
            roles,
            ["productManifest", "sdkManifest", "node", "hvigor", "java"]
        );
        // The bundled JDK's launcher: executable, its signature verified.
        assert_eq!(children[4]["executable"], true);
        assert_eq!(children[4]["trust"]["signature"], "verified");
        // node: executable, its own Authenticode signature verified and named.
        assert_eq!(children[2]["executable"], true);
        assert_eq!(children[2]["trust"]["signature"], "verified");
        assert_eq!(
            children[2]["trust"]["signingIdentifier"],
            DEVELOPMENT_SIGNER
        );
        assert_eq!(
            children[2]["trust"]["codeDirectoryIdentitySHA256"]
                .as_str()
                .unwrap()
                .len(),
            64
        );
        // hvigor: the script, pinned by its bytes, not itself executable.
        assert_eq!(children[3]["executable"], false);
        assert!(children[3]["trust"].is_null());
        assert_eq!(value["trust"]["signature"], "verified");
        assert_eq!(value["trust"]["signingIdentifier"], DEVELOPMENT_SIGNER);

        // The durable index holds the Windows form and reads back exactly.
        let bytes = scratch.index();
        let (index, document) = read_index(&bytes).unwrap();
        assert_eq!(document, bytes);
        assert_eq!(index.records.len(), 1);
        assert_eq!(index.records[0].root.path, root.to_str().unwrap());
        assert_eq!(index.records[0].registered_at, NOW);
        // The same content again answers the same record and writes nothing;
        // inspect and list re-measure the content.
        assert_eq!(
            store.register(&root, "2026-09-30T01:00:00Z").unwrap(),
            value
        );
        assert_eq!(scratch.index(), bytes);
        assert_eq!(store.inspect(&reference).unwrap(), value);
        assert_eq!(store.list().unwrap(), vec![value.clone()]);

        // Other hvigor bytes: the registered reference no longer verifies,
        // and the index is left as it was.
        scratch.file(
            r"DevEco Studio\tools\hvigor\bin\hvigorw.js",
            b"// another wrapper\n",
        );
        assert_eq!(
            store.inspect(&reference).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(scratch.index(), bytes);
    }

    /// Retirement through the Bootstrap store's shared retirement binding, as
    /// the HDC tool registry retires: metadata only, once, and the retired
    /// record reads back; the DevEco content is not touched.
    #[test]
    fn a_registered_toolchain_retires_once_and_reads_back_removed() {
        let scratch = Scratch::new("deveco-retirement");
        let Some(root) = scratch.deveco(true) else {
            return;
        };
        let _publisher = Publisher::development();
        let store = scratch.store();
        let value = store.register(&root, NOW).unwrap();
        let reference = value["toolRef"].as_str().unwrap().to_owned();
        let absent = format!("toolchain:sha256:{}", "0".repeat(64));
        assert_eq!(
            store.retire(&absent, "1").unwrap_err().code,
            "resourceNotFound"
        );
        assert_eq!(
            store.retire(&reference, "2").unwrap_err().code,
            "resourceConflict"
        );
        let retired = store.retire(&reference, "1").unwrap();
        assert_eq!(retired["state"], "removed");
        assert_eq!(retired["generation"], "2");
        let written = scratch.index();
        // A retry answers the same receipt and writes nothing.
        assert_eq!(store.retire(&reference, "1").unwrap(), retired);
        assert_eq!(scratch.index(), written);
        assert_eq!(store.inspect(&reference).unwrap(), retired);
        assert!(root.join("tools").join("node").join("node.exe").is_file());
    }

    /// A workspace preset's pin on a Windows toolchain, through the same
    /// acquire and release as macOS (`deveco_pins.rs`): the content is
    /// re-verified, a pin at a stale generation is refused, a pinned
    /// toolchain is not retired, a release lets it retire, and a second pin
    /// or release changes nothing. The DevEco content is not touched.
    #[test]
    fn a_preset_pins_a_windows_toolchain_until_it_releases_it() {
        let scratch = Scratch::new("deveco-pins");
        let Some(root) = scratch.deveco(true) else {
            return;
        };
        let _publisher = Publisher::development();
        let store = scratch.store();
        let value = store.register(&root, NOW).unwrap();
        let reference = value["toolRef"].as_str().unwrap().to_owned();
        let pinned = store
            .acquire(&reference, "1", "workspacePreset", "preset-build")
            .unwrap();
        assert_eq!(
            pinned["references"],
            json!([{"kind": "workspacePreset", "id": "preset-build"}]),
            "{pinned}"
        );
        let written = scratch.index();
        assert_eq!(
            store
                .acquire(&reference, "1", "workspacePreset", "preset-build")
                .unwrap(),
            pinned
        );
        assert_eq!(scratch.index(), written, "a held pin is kept as it is");
        assert_eq!(
            store
                .acquire(&reference, "2", "workspacePreset", "preset-other")
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        assert_eq!(
            store.retire(&reference, "1").unwrap_err().code,
            "resourceConflict",
            "a pinned toolchain is retained"
        );
        store
            .release(&reference, "workspacePreset", "preset-build")
            .unwrap();
        let released = scratch.index();
        store
            .release(&reference, "workspacePreset", "preset-build")
            .unwrap();
        assert_eq!(scratch.index(), released, "an absent pin stays absent");
        assert_eq!(store.retire(&reference, "1").unwrap()["state"], "removed");
        assert!(root.join("tools").join("node").join("node.exe").is_file());
    }

    #[test]
    fn an_unsigned_node_or_another_publisher_is_refused_before_anything_is_written() {
        let scratch = Scratch::new("deveco-registration-refusals");
        let Some(root) = scratch.deveco(false) else {
            return;
        };
        let store = scratch.store();
        {
            let _publisher = Publisher::development();
            assert_eq!(
                store.register(&root, NOW).unwrap_err().code,
                "admissionDenied"
            );
        }
        // node signed now, but the launcher is not the DevEco publisher's.
        assert!(scratch.executable(r"DevEco Studio\tools\node\node.exe", "hostname.exe", true));
        assert_eq!(
            store.register(&root, NOW).unwrap_err().code,
            "admissionDenied"
        );
        // The DevEco publisher's launcher, but an unsigned JDK launcher.
        {
            let _publisher = Publisher::development();
            assert!(scratch.executable(r"DevEco Studio\jbr\bin\java.exe", "where.exe", false));
            assert_eq!(
                store.register(&root, NOW).unwrap_err().code,
                "admissionDenied"
            );
        }
        assert_eq!(scratch.index(), EMPTY_DEVECO);
    }

    #[test]
    fn only_a_windows_deveco_root_spelled_as_on_disk_is_a_source() {
        let scratch = Scratch::new("deveco-registration-sources");
        let store = scratch.store();
        let root = scratch.0.join("DevEco Studio");
        let text = root.to_str().unwrap();
        for source in [
            "DevEco Studio".to_owned(),
            text.replace('\\', "/"),
            format!(r"{text}\."),
            format!(r"{text}\..\DevEco Studio"),
            "/Applications/DevEco-Studio.app/Contents".to_owned(),
            format!(r"\\?\{text}"),
        ] {
            assert_eq!(
                store.register(Path::new(&source), NOW).unwrap_err().code,
                "invalidInput",
                "{source}"
            );
        }
        // Absent, or not a DevEco layout: the reader refuses it.
        assert_eq!(
            store.register(&root, NOW).unwrap_err().code,
            "fileIdentityChanged"
        );
        scratch.directories("DevEco Studio");
        assert_eq!(
            store
                .register(Path::new(&format!(r"{text}\")), NOW)
                .unwrap_err()
                .code,
            "fileIdentityChanged"
        );
    }

    #[test]
    fn a_macos_record_is_not_this_hosts() {
        let child = |role: &str| {
            json!({"role":role,"relativePath":"x","device":1,"inode":2,"byteCount":1,
                "modifiedSeconds":0,"modifiedNanos":0,"changedSeconds":0,"changedNanos":0,
                "sha256":"b".repeat(64),"executable":false})
        };
        let record = |path: &str, roles: &[&str]| {
            json!({"schemaVersion":"arkdeck.bootstrap-deveco-toolchains/1","records":[{
                "reference":format!("toolchain:sha256:{}", "a".repeat(64)),"contentDigest":"a".repeat(64),
                "root":{"path":path,"device":1,"inode":2,"modifiedSeconds":0,"modifiedNanos":0,
                    "changedSeconds":0,"changedNanos":0},
                "productVersion":"6.0.0.868","buildNumber":"DS-253.1.2","sdkVersion":"6.0.0.43",
                "apiVersion":"26","registeredAtUTC":NOW,"bundleTrust":{"signature":"verified"},
                "children":roles.iter().map(|role| child(role)).collect::<Vec<_>>(),
                "generation":1,"state":"available","references":[]}]})
        };
        let windows = ["productManifest", "sdkManifest", "node", "hvigor", "java"];
        // A record registered before the JDK was pinned stays readable.
        let legacy = ["productManifest", "sdkManifest", "node", "hvigor"];
        assert!(
            read_index(&serde_json::to_vec(&record(r"C:\DevEco Studio", &legacy)).unwrap()).is_ok()
        );
        let macos = [
            "productManifest",
            "sdkManifest",
            "node",
            "hvigor",
            "signedResourceEnvelope",
        ];
        assert!(
            read_index(&serde_json::to_vec(&record(r"C:\DevEco Studio", &windows)).unwrap())
                .is_ok()
        );
        for (path, roles) in [
            ("/Applications/DevEco-Studio.app/Contents", &macos[..]),
            (r"C:\DevEco Studio", &macos[..]),
            ("/Applications/DevEco-Studio.app/Contents", &windows[..]),
            ("C:/DevEco Studio", &windows[..]),
            (r"C:\DevEco Studio\..\x", &windows[..]),
        ] {
            assert!(
                read_index(&serde_json::to_vec(&record(path, roles)).unwrap()).is_err(),
                "{path} {roles:?}"
            );
        }
    }

    /// The host's real DevEco Studio, read only: node signed by the OpenJS
    /// Foundation, the launcher by the DevEco publisher.
    #[test]
    #[ignore = "requires ARKDECK_LIVE_DEVECO_ROOT naming an installed DevEco Studio directory"]
    fn the_installed_deveco_studio_registers() {
        let source =
            PathBuf::from(std::env::var_os("ARKDECK_LIVE_DEVECO_ROOT").expect("DevEco root"));
        let scratch = Scratch::new("deveco-registration-live");
        let value = scratch.store().register(&source, NOW).unwrap();
        assert_eq!(value["platform"], "windows");
        let children = value["childTools"].as_array().unwrap();
        assert_eq!(children[2]["trust"]["signature"], "verified");
        assert_eq!(
            children[2]["trust"]["signingIdentifier"],
            "OpenJS Foundation"
        );
        assert_eq!(
            value["trust"]["signingIdentifier"],
            arkdeck_platform::DEVECO_PUBLISHER
        );
        for method in ["runtime.tool.register", "runtime.tool.inspect"] {
            if let Err(error) = arkdeck_contract::validate_method_value(method, "result", &value) {
                panic!("{method}: {error:?}\n{value:#}");
            }
        }
    }
}
