//! Durable cleanup/export preview records, compatible with the Swift owners.
//! The configuration lock must remain held through preview, revalidation,
//! publication of intent, deletion, and publication of the final result.
use crate::{roundtrip, session_time::session_timestamp, snapshot_pager::failure};
use arkdeck_contract::WireError;
use arkdeck_platform::{HostDirectory, HostReadLock, host_gregorian_timestamp};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    io,
    path::{Path, PathBuf},
};

const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_RECORDS: usize = 64;
const OWNER_LOCK: &str = ".session-storage.lock";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CleanupState {
    Ready,
    Applying,
    Applied,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CleanupRecord {
    #[serde(rename = "schemaVersion")]
    schema_version: String,
    #[serde(rename = "previewID")]
    pub preview_id: String,
    #[serde(rename = "previewDigest")]
    pub preview_digest: String,
    #[serde(rename = "expiresAtUTC")]
    pub expires_at_utc: String,
    pub state: CleanupState,
    pub preview: Value,
    pub result: Value,
}

fn unreadable(_: impl std::fmt::Debug) -> WireError {
    failure(
        "recordUnreadable",
        "Session preview record is unreadable or unsafe",
    )
}
pub(crate) fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_digit() || (b'a'..=b'f').contains(&b)
            }
        })
}
fn expiry(value: &str) -> Option<f64> {
    let time = session_timestamp(value)?;
    let formatted = host_gregorian_timestamp(time)?;
    (format!("{}Z", formatted.split('.').next()?) == value).then_some(time)
}
fn filename(id: &str, export: bool) -> String {
    format!("{}-{id}.json", if export { "export" } else { "cleanup" })
}
fn schema(export: bool) -> &'static str {
    if export {
        "arkdeck.session-export-record/1"
    } else {
        "arkdeck.session-cleanup-record/1"
    }
}
impl CleanupRecord {
    fn validate(&self, export: bool) -> Result<(), WireError> {
        if self.schema_version != schema(export)
            || !uuid(&self.preview_id)
            || self.preview_digest.len() != 64
            || !self
                .preview_digest
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || expiry(&self.expires_at_utc).is_none()
            || !self.preview.is_object()
            || self.preview["previewId"] != self.preview_id
            || self.preview["previewDigest"] != self.preview_digest
            || self.preview["expiresAtUtc"] != self.expires_at_utc
            || (self.state == CleanupState::Applied) == self.result.is_null()
        {
            return Err(unreadable("invalid identity or state"));
        }
        Ok(())
    }
}

/// Export-only release. The owner may use this transition only after the
/// staging/publication boundary mechanically proves no destination publication.
impl SessionPreviewRecords<'_, true> {
    pub fn restore_ready_before_publication(
        &self,
        record: &CleanupRecord,
    ) -> Result<CleanupRecord, WireError> {
        self.transition(
            record,
            CleanupState::Applying,
            CleanupState::Ready,
            Value::Null,
        )
    }
}

/// Requires the real Session configuration lock, also used by the Swift owner.
/// It adds no private lock file to the closed cleanup-record directory.
pub struct SessionPreviewRecords<'a, const EXPORT: bool> {
    root: HostDirectory,
    path: PathBuf,
    owner: &'a HostDirectory,
    lock: &'a HostReadLock,
}
pub type SessionCleanupRecords<'a> = SessionPreviewRecords<'a, false>;
pub type SessionExportRecords<'a> = SessionPreviewRecords<'a, true>;

impl<'a, const EXPORT: bool> SessionPreviewRecords<'a, EXPORT> {
    pub fn open(
        path: &Path,
        owner: &'a HostDirectory,
        lock: &'a HostReadLock,
    ) -> Result<Self, WireError> {
        let result = Self {
            root: HostDirectory::open(path).map_err(unreadable)?,
            path: path.into(),
            owner,
            lock,
        };
        result.validate()?;
        Ok(result)
    }
    fn validate(&self) -> Result<(), WireError> {
        self.lock
            .validate_link(self.owner, OWNER_LOCK)
            .map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)
    }
    pub fn load(&self, id: &str) -> Result<CleanupRecord, WireError> {
        if !uuid(id) {
            return Err(failure(
                "invalidInput",
                "Session preview identity is malformed",
            ));
        }
        self.validate()?;
        let bytes = self
            .root
            .read(&filename(id, EXPORT), MAX_BYTES)
            .map_err(|error| {
                if error.kind() == io::ErrorKind::NotFound {
                    failure("resourceNotFound", "Session preview is not present")
                } else {
                    unreadable(error)
                }
            })?;
        let (record, canonical) =
            roundtrip::<CleanupRecord>(&bytes, MAX_BYTES, true).map_err(unreadable)?;
        record.validate(EXPORT)?;
        if canonical != bytes || record.preview_id != id {
            return Err(unreadable("noncanonical record"));
        }
        self.validate()?;
        Ok(record)
    }
    pub fn create(&self, preview: Value, now: f64) -> Result<CleanupRecord, WireError> {
        let field = |key| {
            preview[key]
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| unreadable("missing identity"))
        };
        let record = CleanupRecord {
            schema_version: schema(EXPORT).into(),
            preview_id: field("previewId")?,
            preview_digest: field("previewDigest")?,
            expires_at_utc: field("expiresAtUtc")?,
            state: CleanupState::Ready,
            preview,
            result: Value::Null,
        };
        record.validate(EXPORT)?;
        self.retain_space(now)?;
        match self
            .root
            .document_metadata(&filename(&record.preview_id, EXPORT))
        {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            _ => {
                return Err(failure(
                    "resourceConflict",
                    "Session preview identity already exists",
                ));
            }
        }
        self.save(&record)?;
        Ok(record)
    }
    pub fn mark_applying(&self, record: &CleanupRecord) -> Result<CleanupRecord, WireError> {
        self.transition(
            record,
            CleanupState::Ready,
            CleanupState::Applying,
            Value::Null,
        )
    }
    pub fn mark_applied(
        &self,
        record: &CleanupRecord,
        result: Value,
    ) -> Result<CleanupRecord, WireError> {
        self.transition(
            record,
            CleanupState::Applying,
            CleanupState::Applied,
            result,
        )
    }
    /// Only the owner may call this after proving staleSnapshot caused zero deletion.
    pub fn restore_ready_after_stale_snapshot(
        &self,
        record: &CleanupRecord,
    ) -> Result<CleanupRecord, WireError> {
        self.transition(
            record,
            CleanupState::Applying,
            CleanupState::Ready,
            Value::Null,
        )
    }
    fn transition(
        &self,
        record: &CleanupRecord,
        from: CleanupState,
        to: CleanupState,
        result: Value,
    ) -> Result<CleanupRecord, WireError> {
        if record.state != from
            || !record.result.is_null()
            || self.load(&record.preview_id)? != *record
        {
            return Err(unreadable("invalid or stale transition"));
        }
        let mut updated = record.clone();
        updated.state = to;
        updated.result = result;
        self.save(&updated)?;
        Ok(updated)
    }
    fn save(&self, record: &CleanupRecord) -> Result<(), WireError> {
        record.validate(EXPORT)?;
        let value = serde_json::to_value(record).map_err(unreadable)?;
        let mut bytes = serde_json::to_vec(&value).map_err(unreadable)?;
        bytes.push(b'\n');
        if bytes.len() > MAX_BYTES {
            return Err(failure(
                "quotaExceeded",
                "Session preview exceeds its byte bound",
            ));
        }
        self.validate()?;
        self.root
            .publish_document(&filename(&record.preview_id, EXPORT), &bytes, MAX_BYTES)
            .map_err(|_| {
                failure(
                    "outcomeUnknown",
                    "Session preview record publication is uncertain",
                )
            })?;
        if self.validate().is_err()
            || self
                .root
                .read(&filename(&record.preview_id, EXPORT), MAX_BYTES)
                .ok()
                .as_ref()
                != Some(&bytes)
        {
            return Err(failure(
                "outcomeUnknown",
                "Session preview record publication cannot be read back",
            ));
        }
        Ok(())
    }
    fn retain_space(&self, now: f64) -> Result<(), WireError> {
        if !now.is_finite() {
            return Err(failure(
                "operationUnavailable",
                "Runtime clock is unavailable",
            ));
        }
        self.validate()?;
        let mut names = self.root.names(MAX_RECORDS).map_err(unreadable)?;
        names.sort();
        let mut retained = 0;
        for name in names {
            let id = name
                .strip_prefix(if EXPORT { "export-" } else { "cleanup-" })
                .and_then(|name| name.strip_suffix(".json"))
                .ok_or_else(|| unreadable("unknown record"))?;
            let metadata = self.root.document_metadata(&name).map_err(unreadable)?;
            let record = self.load(id)?;
            if expiry(&record.expires_at_utc).is_some_and(|time| time <= now)
                && record.state != CleanupState::Applying
            {
                self.validate()?;
                self.root
                    .remove_document(&name, &metadata)
                    .map_err(|_| failure("ioFailure", "Session preview record retention failed"))?;
            } else {
                retained += 1;
            }
        }
        if retained >= MAX_RECORDS {
            return Err(failure(
                "quotaExceeded",
                "Session preview capacity is exhausted",
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
    };
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let bytes = arkdeck_platform::random_bytes::<16>().unwrap();
            let suffix: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("cleanup-records-{suffix}"));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            fs::DirBuilder::new()
                .mode(0o700)
                .create(path.join("records"))
                .unwrap();
            Self(path)
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn preview(index: u64) -> Value {
        json!({"previewId": format!("00000000-0000-0000-0000-{index:012x}"), "previewDigest":"a".repeat(64), "expiresAtUtc":"2026-09-11T00:00:00Z"})
    }
    fn time(text: &str) -> f64 {
        session_timestamp(text).unwrap()
    }
    #[test]
    fn export_records_preserve_their_schema_and_cannot_be_loaded_as_cleanup_records() {
        let root = Root::new();
        let owner = HostDirectory::open(&root.0).unwrap();
        let lock = owner.lock_document(OWNER_LOCK).unwrap();
        let path = root.0.join("records");
        let export = SessionExportRecords::open(&path, &owner, &lock).unwrap();
        let record = export
            .create(preview(1), time("2026-09-10T00:00:00Z"))
            .unwrap();
        let bytes = fs::read(path.join(filename(&record.preview_id, true))).unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&bytes).unwrap()["schemaVersion"],
            "arkdeck.session-export-record/1"
        );
        assert_eq!(export.load(&record.preview_id).unwrap(), record);
        let cleanup = SessionCleanupRecords::open(&path, &owner, &lock).unwrap();
        assert_eq!(
            cleanup.load(&record.preview_id).unwrap_err().code,
            "resourceNotFound"
        );
        let forged = path.join(filename(&record.preview_id, false));
        fs::write(&forged, &bytes).unwrap();
        fs::set_permissions(&forged, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            cleanup.load(&record.preview_id).unwrap_err().code,
            "recordUnreadable"
        );
        assert_eq!(
            fs::read(path.join(filename(&record.preview_id, true))).unwrap(),
            bytes
        );
    }

    #[test]
    fn restart_preserves_intent_and_stale_ready_cannot_overwrite_it() {
        let root = Root::new();
        let owner = HostDirectory::open(&root.0).unwrap();
        let lock = owner.lock_document(OWNER_LOCK).unwrap();
        let store = SessionCleanupRecords::open(&root.0.join("records"), &owner, &lock).unwrap();
        let ready = store
            .create(preview(1), time("2026-09-10T00:00:00Z"))
            .unwrap();
        let applying = store.mark_applying(&ready).unwrap();
        drop(store);
        let restarted =
            SessionCleanupRecords::open(&root.0.join("records"), &owner, &lock).unwrap();
        assert_eq!(restarted.load(&ready.preview_id).unwrap(), applying);
        assert_eq!(
            restarted.mark_applying(&ready).unwrap_err().code,
            "recordUnreadable"
        );
        let result = json!({"removedSessionIds":["one"], "newDispatchCount":0});
        let applied = restarted.mark_applied(&applying, result.clone()).unwrap();
        assert_eq!(restarted.load(&ready.preview_id).unwrap().result, result);
        assert_eq!(applied.state, CleanupState::Applied);
        assert!(
            restarted
                .restore_ready_after_stale_snapshot(&applied)
                .is_err()
        );
    }
    #[test]
    fn expiry_reclaims_ready_and_applied_but_never_uncertain_intent() {
        let root = Root::new();
        let owner = HostDirectory::open(&root.0).unwrap();
        let lock = owner.lock_document(OWNER_LOCK).unwrap();
        let store = SessionCleanupRecords::open(&root.0.join("records"), &owner, &lock).unwrap();
        let now = time("2026-09-10T00:00:00Z");
        let ready = store.create(preview(1), now).unwrap();
        let applying = store
            .mark_applying(&store.create(preview(2), now).unwrap())
            .unwrap();
        let applied = store
            .mark_applied(
                &store
                    .mark_applying(&store.create(preview(3), now).unwrap())
                    .unwrap(),
                json!({}),
            )
            .unwrap();
        store
            .create(preview(4), time("2026-09-11T00:00:00Z"))
            .unwrap();
        assert_eq!(
            store.load(&ready.preview_id).unwrap_err().code,
            "resourceNotFound"
        );
        assert_eq!(
            store.load(&applied.preview_id).unwrap_err().code,
            "resourceNotFound"
        );
        assert_eq!(store.load(&applying.preview_id).unwrap(), applying);
    }
    #[test]
    fn full_uncertain_store_refuses_new_preview_without_reclaiming_intent() {
        let root = Root::new();
        let owner = HostDirectory::open(&root.0).unwrap();
        let lock = owner.lock_document(OWNER_LOCK).unwrap();
        let store = SessionCleanupRecords::open(&root.0.join("records"), &owner, &lock).unwrap();
        let now = time("2026-09-10T00:00:00Z");
        for index in 0..64 {
            store
                .mark_applying(&store.create(preview(index), now).unwrap())
                .unwrap();
        }
        assert_eq!(
            store
                .create(preview(64), time("2026-09-12T00:00:00Z"))
                .unwrap_err()
                .code,
            "quotaExceeded"
        );
        assert_eq!(fs::read_dir(root.0.join("records")).unwrap().count(), 64);
    }
    #[test]
    fn malformed_and_replaced_files_fail_closed_without_removal() {
        let root = Root::new();
        let owner = HostDirectory::open(&root.0).unwrap();
        let lock = owner.lock_document(OWNER_LOCK).unwrap();
        let store = SessionCleanupRecords::open(&root.0.join("records"), &owner, &lock).unwrap();
        let now = time("2026-09-10T00:00:00Z");
        let record = store.create(preview(1), now).unwrap();
        let path = root
            .0
            .join("records")
            .join(filename(&record.preview_id, false));
        let original = fs::read(&path).unwrap();
        let mut without_newline = original.clone();
        without_newline.pop();
        fs::write(&path, without_newline).unwrap();
        assert_eq!(
            store.load(&record.preview_id).unwrap_err().code,
            "recordUnreadable"
        );
        fs::write(&path, &original).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(store.load(&record.preview_id).is_err());
        fs::remove_file(&path).unwrap();
        let outside = root.0.join("outside.json");
        fs::write(&outside, &original).unwrap();
        symlink(&outside, &path).unwrap();
        assert!(
            store
                .create(preview(2), time("2026-09-12T00:00:00Z"))
                .is_err()
        );
        assert_eq!(fs::read(&outside).unwrap(), original);
    }
    #[test]
    fn invalid_expiry_and_identity_do_not_create_records() {
        let root = Root::new();
        let owner = HostDirectory::open(&root.0).unwrap();
        let lock = owner.lock_document(OWNER_LOCK).unwrap();
        let store = SessionCleanupRecords::open(&root.0.join("records"), &owner, &lock).unwrap();
        for date in [
            "2026-09-11T00:00:00.000Z",
            "2026-09-11T00:00:00+00:00",
            "2026-02-30T00:00:00Z",
        ] {
            let mut value = preview(1);
            value["expiresAtUtc"] = json!(date);
            assert!(store.create(value, 0.0).is_err(), "{date}");
        }
        let mut value = preview(1);
        value["previewId"] = json!("../other");
        assert!(store.create(value, 0.0).is_err());
        assert_eq!(fs::read_dir(root.0.join("records")).unwrap().count(), 0);
    }
}
