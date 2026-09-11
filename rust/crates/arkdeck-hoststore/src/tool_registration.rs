//! HDC registration writes only frozen Bootstrap metadata and immutable content.
//! Capturing a native executable does not select it or confer execution authority.
use crate::{
    ToolRegistryStore, decode_bundles, decode_tools,
    tool_content::{ToolContent, inspect_tool_content},
    tool_macho,
    tool_registry_owner::matches,
};
use arkdeck_contract::WireError;
use arkdeck_platform::{
    BootstrapToolCapture, BootstrapToolCaptureError, BootstrapToolPublishError,
    DocumentPublishError, HostReadLock, NativeCodeSignature, inspect_bootstrap_tree,
};
use serde_json::{Value, json};
use std::{io, path::Path};

const MAX_INDEX: usize = 4 * 1024 * 1024;
const MAX_TOOL_BYTES: u64 = 256 * 1024 * 1024;
const MAX_RETAINED_BYTES: u64 = 2 * 1024 * 1024 * 1024;
const EMPTY_BUNDLES: &[u8] = b"{\"records\":[],\"schemaVersion\":\"arkdeck.bootstrap-bundles/1\"}";
const EMPTY_TOOLS: &[u8] = b"{\"records\":[],\"schemaVersion\":\"arkdeck.bootstrap-tools/2\"}";

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
        "Bootstrap tool metadata or retained content is unreadable",
    )
}
fn unknown(_: impl std::fmt::Debug) -> WireError {
    failure(
        "outcomeUnknown",
        "HDC registration publication is unconfirmed; inspect before another request",
    )
}
fn publication(error: DocumentPublishError) -> WireError {
    match error {
        DocumentPublishError::BeforePublication(_) => {
            failure("ioFailure", "Bootstrap metadata could not be published")
        }
        DocumentPublishError::OutcomeUnknown(_) => unknown(error),
    }
}
fn captured(error: BootstrapToolCaptureError) -> WireError {
    failure(error.code, error.message)
}
fn native(error: io::Error) -> WireError {
    match error.kind() {
        io::ErrorKind::PermissionDenied => failure(
            "admissionDenied",
            "HDC content failed native trust validation",
        ),
        io::ErrorKind::InvalidData | io::ErrorKind::NotFound => failure(
            "fileIdentityChanged",
            "captured HDC content changed during native verification",
        ),
        _ => failure("ioFailure", "HDC native inspection could not complete"),
    }
}
fn trust(trust: &NativeCodeSignature) -> Value {
    let mut value = json!({"signature":trust.signature,"identifier":trust.identifier,
        "teamIdentifier":trust.team_identifier,"codeDirectorySHA256":trust.code_directory_sha256});
    value
        .as_object_mut()
        .expect("object")
        .retain(|_, value| !value.is_null());
    value
}
fn record(content: &ToolContent, now: &str) -> Value {
    let dependencies: Vec<_> = content
        .dependencies
        .iter()
        .map(|dependency| {
            let mut value = json!({"name":dependency.name,"sha256":dependency.sha256,
            "byteCount":dependency.byte_count,"quarantineSHA256":dependency.quarantine_sha256,
            "trust":trust(&dependency.trust)});
            value
                .as_object_mut()
                .expect("object")
                .retain(|_, value| !value.is_null());
            value
        })
        .collect();
    let mut value = json!({"reference":format!("tool:sha256:{}",content.digest),
        "contentDigest":content.digest,"executableSHA256":content.sha256,"registeredAt":now,
        "byteCount":content.byte_count,"quarantineSHA256":content.quarantine_sha256,
        "trust":trust(&content.trust),"dependencies":dependencies,"relocatable":content.relocatable,
        "generation":1,"state":"available","references":[]});
    value
        .as_object_mut()
        .expect("object")
        .retain(|_, value| !value.is_null());
    value
}
fn projection(bytes: &[u8], reference: &str) -> Result<Value, WireError> {
    decode_tools(bytes)
        .map_err(unreadable)?
        .projection
        .as_array()
        .ok_or_else(|| unreadable("projection"))?
        .iter()
        .find(|value| value["toolRef"] == reference)
        .cloned()
        .ok_or_else(|| unreadable("missing reference"))
}

impl ToolRegistryStore {
    /// Clock comes from the host, not the wire. Source bytes are captured under
    /// the Bootstrap lock and are never executed, selected or deleted here.
    pub fn register(&self, source: &Path, now: &str) -> Result<Value, WireError> {
        self.register_with_checkpoint(source, now, |_| Ok(()))
    }
    fn registration_identity(&self, lock: &HostReadLock) -> Result<(), WireError> {
        lock.validate_link(&self.root, ".lock")
            .map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)
    }
    fn registration_bytes(
        &self,
        lock: &HostReadLock,
        bundles: &[u8],
        tools: &[u8],
    ) -> Result<(), WireError> {
        self.registration_identity(lock)?;
        if self
            .root
            .read("bundles.json", MAX_INDEX)
            .map_err(unreadable)?
            != bundles
            || self
                .root
                .read("tools.json", MAX_INDEX)
                .map_err(unreadable)?
                != tools
        {
            return Err(unreadable("indexes changed during registration"));
        }
        Ok(())
    }
    fn retained_tool_bytes(&self) -> Result<u64, WireError> {
        let names = self.root.names(65_536).map_err(unreadable)?;
        if names.len() > 300 {
            return Err(failure("quotaExceeded", "Bootstrap entry bound reached"));
        }
        let mut bytes = 0u64;
        let mut interrupted = 0;
        for name in names {
            let staging = name.starts_with(".tool-staging-");
            if !(staging || (name.starts_with("tool-") && name.ends_with(".hdc"))) {
                continue;
            }
            if staging {
                interrupted += 1;
            }
            if interrupted >= 4 {
                return Err(failure(
                    "quotaExceeded",
                    "interrupted tool captures require inspection",
                ));
            }
            let held = self.root.child(&name).map_err(unreadable)?;
            let path = self.path.join(&name);
            let tree = inspect_bootstrap_tree(&path).map_err(unreadable)?;
            if tree.entries.len() > 3 || tree.byte_count > MAX_TOOL_BYTES {
                return Err(unreadable("retained tool exceeds its content bounds"));
            }
            held.validate_path(&path).map_err(unreadable)?;
            bytes = bytes
                .checked_add(tree.byte_count)
                .ok_or_else(|| unreadable("retained byte overflow"))?;
            if bytes > MAX_RETAINED_BYTES {
                return Err(failure(
                    "quotaExceeded",
                    "retained HDC content exceeds its quota",
                ));
            }
        }
        Ok(bytes)
    }
    fn verify_tool_record(&self, record: &Value) -> Result<(), WireError> {
        let digest = record["contentDigest"]
            .as_str()
            .ok_or_else(|| unreadable("digest"))?;
        let name = format!("tool-{digest}.hdc");
        let path = self.path.join(&name);
        let held = self.root.child(&name).map_err(unreadable)?;
        let content = inspect_tool_content(&path).map_err(unreadable)?;
        if !matches(record, &content) {
            return Err(unreadable("retained tool identity changed"));
        }
        held.validate_path(&path).map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)
    }
    fn register_with_checkpoint(
        &self,
        source: &Path,
        now: &str,
        checkpoint: impl Fn(&str) -> io::Result<()>,
    ) -> Result<Value, WireError> {
        let text = source
            .to_str()
            .ok_or_else(|| failure("invalidInput", "a local file is required"))?;
        if !text.starts_with('/')
            || text.as_bytes().contains(&0)
            || text.split('/').any(|part| matches!(part, "." | ".."))
            || arkdeck_platform::host_legacy_iso8601(now) != Some(true)
        {
            return Err(failure(
                "invalidInput",
                "the local file or host timestamp is invalid",
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
                    return Err(unreadable("bundle index missing beside retained state"));
                }
                self.registration_identity(&lock)?;
                self.root
                    .publish_document("bundles.json", EMPTY_BUNDLES, MAX_INDEX)
                    .map_err(publication)?;
                EMPTY_BUNDLES.to_vec()
            }
            Err(error) => return Err(unreadable(error)),
        };
        let bytes = match self.root.read("tools.json", MAX_INDEX) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if self
                    .root
                    .names(65_536)
                    .map_err(unreadable)?
                    .iter()
                    .any(|name| name.starts_with("tool-") || name.starts_with(".tool-"))
                {
                    return Err(unreadable("tool index missing beside retained state"));
                }
                self.registration_identity(&lock)?;
                self.root
                    .publish_document("tools.json", EMPTY_TOOLS, MAX_INDEX)
                    .map_err(publication)?;
                EMPTY_TOOLS.to_vec()
            }
            Err(error) => return Err(unreadable(error)),
        };
        let decoded = decode_tools(&bytes).map_err(unreadable)?;
        let mut index: Value = serde_json::from_slice(&decoded.document).map_err(unreadable)?;
        let retained = self.retained_tool_bytes()?;
        let mut stage = BootstrapToolCapture::capture(&self.path, source, |file, library| {
            let slices = tool_macho::inspect(file).map_err(|error| BootstrapToolCaptureError {
                code: error.code,
                message: error.message,
            })?;
            if slices
                .iter()
                .any(|slice| slice.file_type != if library { 6 } else { 2 })
            {
                return Err(BootstrapToolCaptureError {
                    code: "invalidInput",
                    message: "host tool entry has the wrong native kind",
                });
            }
            Ok(tool_macho::needs_usb(&slices))
        })
        .map_err(captured)?;
        checkpoint("copied").map_err(unreadable)?;
        stage.revalidate_sources().map_err(captured)?;
        let content = inspect_tool_content(stage.path()).map_err(native)?;
        stage.revalidate_sources().map_err(captured)?;
        let reference = format!("tool:sha256:{}", content.digest);
        if let Some(old) = index["records"]
            .as_array()
            .ok_or_else(|| unreadable("records"))?
            .iter()
            .find(|row| row["reference"] == reference)
        {
            if old["state"] != "available" {
                return Err(failure(
                    "resourceConflict",
                    "this exact tool is retired; its historical content remains retained",
                ));
            }
            self.verify_tool_record(old)?;
            self.registration_bytes(&lock, &bundles, &bytes)?;
            return projection(&bytes, &reference);
        }
        let record = record(&content, now);
        let name = format!("tool-{}.hdc", content.digest);
        let exists = match self.root.child(&name) {
            Ok(_) => {
                self.verify_tool_record(&record)?;
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
            || retained > MAX_RETAINED_BYTES - if exists { 0 } else { content.byte_count }
        {
            return Err(failure(
                "quotaExceeded",
                "registered HDC tools exceed the Bootstrap quota",
            ));
        }
        index["schemaVersion"] = json!("arkdeck.bootstrap-tools/2");
        let records = index["records"]
            .as_array_mut()
            .ok_or_else(|| unreadable("records"))?;
        records.push(record.clone());
        records.sort_by(|left, right| left["reference"].as_str().cmp(&right["reference"].as_str()));
        let encoded = serde_json::to_vec(&index).map_err(unreadable)?;
        if encoded.len() > MAX_INDEX {
            return Err(failure(
                "quotaExceeded",
                "HDC registry exceeds its storage bound",
            ));
        }
        let document = decode_tools(&encoded).map_err(unreadable)?.document;
        let result = projection(&document, &reference)?;
        self.registration_bytes(&lock, &bundles, &bytes)?;
        checkpoint("beforeContentPublication").map_err(unreadable)?;
        self.registration_bytes(&lock, &bundles, &bytes)?;
        stage.revalidate_sources().map_err(captured)?;
        // The primitive never overwrites an existing immutable destination and
        // never deletes retained content if a later index publication fails.
        stage
            .publish(&content.digest)
            .map_err(|error| match error {
                BootstrapToolPublishError::BeforePublication(error) => captured(error),
                BootstrapToolPublishError::OutcomeUnknown(error) => unknown(error),
            })?;
        checkpoint("contentPublished").map_err(unknown)?;
        self.verify_tool_record(&record).map_err(unknown)?;
        self.registration_bytes(&lock, &bundles, &bytes)
            .map_err(unknown)?;
        self.root
            .publish_document("tools.json", &document, MAX_INDEX)
            .map_err(unknown)?;
        if checkpoint("recordPublished").is_err()
            || self.registration_identity(&lock).is_err()
            || self.root.read("tools.json", MAX_INDEX).ok().as_deref() != Some(document.as_slice())
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
    fn root() -> PathBuf {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("hdc-registration-{nonce:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        path
    }
    fn write(root: &Path, name: &str, bytes: &[u8]) {
        fs::write(root.join(name), bytes).unwrap();
        fs::set_permissions(root.join(name), fs::Permissions::from_mode(0o600)).unwrap();
    }
    const NOW: &str = "2026-09-11T00:00:00Z";
    #[test]
    fn registration_initialization_never_heals_missing_indexes_beside_retained_state() {
        let path = root();
        write(&path, "retained", b"leave unchanged");
        let store = ToolRegistryStore::open_existing(&path).unwrap();
        assert_eq!(
            store
                .register(Path::new("/usr/bin/true"), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert!(!path.join("bundles.json").exists());
        assert!(!path.join("tools.json").exists());
        assert_eq!(fs::read(path.join("retained")).unwrap(), b"leave unchanged");

        let path = root();
        write(&path, "bundles.json", EMPTY_BUNDLES);
        fs::DirBuilder::new()
            .mode(0o700)
            .create(path.join(".tool-staging-retained"))
            .unwrap();
        let store = ToolRegistryStore::open_existing(&path).unwrap();
        assert_eq!(
            store
                .register(Path::new("/usr/bin/true"), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert!(!path.join("tools.json").exists());
        assert!(path.join(".tool-staging-retained").is_dir());
    }
    #[test]
    fn malformed_indexes_content_quota_and_lock_refuse_without_capture() {
        let path = root();
        write(&path, "bundles.json", EMPTY_BUNDLES);
        write(&path, "tools.json", b"{broken");
        let store = ToolRegistryStore::open_existing(&path).unwrap();
        assert_eq!(
            store
                .register(Path::new("/usr/bin/true"), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert_eq!(fs::read(path.join("tools.json")).unwrap(), b"{broken");
        write(&path, "tools.json", EMPTY_TOOLS);
        for n in 0..4 {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(path.join(format!(".tool-staging-existing-{n}")))
                .unwrap();
        }
        assert_eq!(
            store
                .register(Path::new("/usr/bin/true"), NOW)
                .unwrap_err()
                .code,
            "quotaExceeded"
        );
        assert_eq!(fs::read(path.join("tools.json")).unwrap(), EMPTY_TOOLS);
        let locked = arkdeck_platform::HostDirectory::open(&path)
            .unwrap()
            .lock_document(".lock")
            .unwrap();
        assert_eq!(
            store
                .register(Path::new("/usr/bin/true"), NOW)
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        drop(locked);
        assert_eq!(fs::read_dir(path).unwrap().count(), 7);
    }
    #[test]
    fn actual_native_registration_is_idempotent_and_reopens_after_uncertain_receipt() {
        // A real native signed Mach-O is eligible for storage inspection even
        // when it is not a published HDC identity. It is never executed here.
        let path = root();
        let source = Path::new("/usr/bin/true");
        let source_bytes = fs::read(source).unwrap();
        let store = ToolRegistryStore::open_existing(&path).unwrap();
        let first = store.register(source, NOW).unwrap();
        let reference = first["toolRef"].as_str().unwrap();
        assert_eq!(first["trust"]["executionAssessment"], "notPerformed");
        assert_eq!(first["trust"]["registeredIdentity"], false);
        let bytes = fs::read(path.join("tools.json")).unwrap();
        assert_eq!(
            store.register(source, "2026-09-11T01:00:00Z").unwrap(),
            first
        );
        assert_eq!(fs::read(path.join("tools.json")).unwrap(), bytes);
        assert_eq!(
            ToolRegistryStore::open_existing(&path)
                .unwrap()
                .inspect(reference)
                .unwrap(),
            first
        );
        assert_eq!(fs::read(source).unwrap(), source_bytes);
        assert_eq!(fs::read_dir(&path).unwrap().count(), 4);

        let uncertain_path = root();
        let uncertain = ToolRegistryStore::open_existing(&uncertain_path).unwrap();
        let error = uncertain
            .register_with_checkpoint(source, NOW, |phase| {
                if phase == "recordPublished" {
                    Err(io::Error::other("test interrupted receipt"))
                } else {
                    Ok(())
                }
            })
            .unwrap_err();
        assert_eq!(error.code, "outcomeUnknown");
        let bytes = fs::read(uncertain_path.join("tools.json")).unwrap();
        let reopened = ToolRegistryStore::open_existing(&uncertain_path).unwrap();
        assert_eq!(reopened.inspect(reference).unwrap(), first);
        // This is an explicit independent invocation, not owner/client replay.
        assert_eq!(
            reopened.register(source, "2026-09-11T02:00:00Z").unwrap(),
            first
        );
        assert_eq!(fs::read(uncertain_path.join("tools.json")).unwrap(), bytes);
        assert_eq!(fs::read_dir(&uncertain_path).unwrap().count(), 4);
    }
    #[test]
    fn content_published_before_interruption_is_retained_and_can_be_registered_independently() {
        let path = root();
        let store = ToolRegistryStore::open_existing(&path).unwrap();
        let source = Path::new("/usr/bin/true");
        let error = store
            .register_with_checkpoint(source, NOW, |phase| {
                if phase == "contentPublished" {
                    Err(io::Error::other("test interrupted content receipt"))
                } else {
                    Ok(())
                }
            })
            .unwrap_err();
        assert_eq!(error.code, "outcomeUnknown");
        assert_eq!(fs::read(path.join("tools.json")).unwrap(), EMPTY_TOOLS);
        let content_name = fs::read_dir(&path)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .find(|name| name.to_str().unwrap().starts_with("tool-"))
            .unwrap();
        let retained = inspect_bootstrap_tree(&path.join(&content_name)).unwrap();
        let result = ToolRegistryStore::open_existing(&path)
            .unwrap()
            .register(source, NOW)
            .unwrap();
        assert_eq!(result["state"], "available");
        assert_eq!(
            inspect_bootstrap_tree(&path.join(content_name)).unwrap(),
            retained
        );
        assert_eq!(fs::read_dir(&path).unwrap().count(), 4);
    }
    #[test]
    fn duplicate_registration_preserves_existing_selection_and_retired_records() {
        let path = root();
        let source = Path::new("/usr/bin/true");
        let store = ToolRegistryStore::open_existing(&path).unwrap();
        let initial = store.register(source, NOW).unwrap();
        let reference = initial["toolRef"].as_str().unwrap();
        let mut index: Value =
            serde_json::from_slice(&fs::read(path.join("tools.json")).unwrap()).unwrap();
        // A frozen metadata fixture tests preservation only. It is not an actual
        // service selection and never grants execution of this native sample.
        index["records"][0]["references"] =
            json!([{"kind":"activeSelection","id":"runtime-hdc-selection"}]);
        index["selection"] = json!({"activeToolRef":reference,"activeGeneration":7});
        let bytes = decode_tools(&serde_json::to_vec(&index).unwrap())
            .unwrap()
            .document;
        write(&path, "tools.json", &bytes);
        let expected = store.inspect(reference).unwrap();
        assert_eq!(expected["selected"], true);
        assert_eq!(expected["activeSelectionGeneration"], "7");
        assert_eq!(
            store.register(source, "2026-09-11T03:00:00Z").unwrap(),
            expected
        );
        assert_eq!(fs::read(path.join("tools.json")).unwrap(), bytes);
        index.as_object_mut().unwrap().remove("selection");
        index["records"][0]["references"] = json!([]);
        index["records"][0]["state"] = json!("removed");
        index["records"][0]["generation"] = json!(2);
        let bytes = decode_tools(&serde_json::to_vec(&index).unwrap())
            .unwrap()
            .document;
        write(&path, "tools.json", &bytes);
        assert_eq!(
            store.register(source, NOW).unwrap_err().code,
            "resourceConflict"
        );
        assert_eq!(fs::read(path.join("tools.json")).unwrap(), bytes);
        assert_eq!(fs::read_dir(&path).unwrap().count(), 4);
    }
    #[test]
    fn explicit_native_hdc_with_sibling_dependency_registers_without_source_writes() {
        let Some(source) = std::env::var_os("ARKDECK_HDC_REGISTER_SOURCE") else {
            eprintln!("SKIP: native HDC source was not explicitly supplied");
            return;
        };
        let source = PathBuf::from(source);
        let sibling = source.parent().unwrap().join("libusb_shared.dylib");
        let before = [fs::read(&source).unwrap(), fs::read(&sibling).unwrap()];
        let path = root();
        let store = ToolRegistryStore::open_existing(&path).unwrap();
        let result = store.register(&source, NOW).unwrap();
        assert_eq!(result["kind"], "hdc");
        assert_eq!(result["trust"]["executionAssessment"], "notPerformed");
        assert_eq!(result["dependencies"].as_array().unwrap().len(), 1);
        assert_eq!(result["dependencies"][0]["name"], "libusb_shared.dylib");
        assert_eq!(result["selected"], false);
        let bytes = fs::read(path.join("tools.json")).unwrap();
        assert_eq!(
            store.register(&source, "2026-09-11T01:00:00Z").unwrap(),
            result
        );
        assert_eq!(fs::read(path.join("tools.json")).unwrap(), bytes);
        let reopened = ToolRegistryStore::open_existing(&path).unwrap();
        assert_eq!(
            reopened
                .inspect(result["toolRef"].as_str().unwrap())
                .unwrap(),
            result
        );
        assert_eq!(
            [fs::read(&source).unwrap(), fs::read(&sibling).unwrap()],
            before
        );
        println!(
            "nativeHDCRegistration={}",
            json!({"bootstrapRoot":path,"result":result,"deviceAcceptance":false})
        );
    }
}
