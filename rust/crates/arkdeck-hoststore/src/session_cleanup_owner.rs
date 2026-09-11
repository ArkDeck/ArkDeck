use super::*;
use crate::{SessionCleanupRecords, session_cleanup_snapshot};
use arkdeck_platform::HostReadLock;
use std::collections::BTreeSet;

const PREVIEWS: &str = "session-cleanup-previews";

impl SessionStore {
    pub fn preview_export(
        &self,
        session_id: &str,
        destination_path: &str,
        allow_sensitive: bool,
        now: f64,
    ) -> Result<Value, WireError> {
        use crate::snapshot_pager::{failure, uuid};
        use crate::{
            SessionExportRecords, session_export_destination_facts, session_export_snapshot,
        };
        if !now.is_finite() {
            return Err(failure(
                "operationUnavailable",
                "Runtime clock is unavailable",
            ));
        }
        self.with_session_configuration(|configuration, path, lock| {
            self.selected_root(path).map_err(|_| {
                failure(
                    "recordUnreadable",
                    "Session storage is unavailable or unsafe",
                )
            })?;
            let snapshot = session_export_snapshot(configuration, path, session_id)?;
            let destination = session_export_destination_facts(destination_path, &self.path, path)?;
            let preview =
                snapshot.preview(&uuid()?, now, now + 600.0, destination, allow_sensitive)?;
            let directory = "session-export-previews";
            self.root
                .private_child(directory)
                .map_err(|_| failure("recordUnreadable", "Session export store is unavailable"))?;
            let records = SessionExportRecords::open(&self.path.join(directory), &self.root, lock)?;
            records.create(preview.clone(), now)?;
            Ok(preview)
        })
    }

    pub fn preview_cleanup(
        &self,
        active_session_ids: &BTreeSet<String>,
        now: f64,
    ) -> Result<Value, WireError> {
        use crate::snapshot_pager::{failure, uuid};
        if !now.is_finite() {
            return Err(failure(
                "operationUnavailable",
                "Runtime clock is unavailable",
            ));
        }
        self.with_session_configuration(|configuration, path, lock| {
            self.selected_root(path).map_err(|_| {
                failure(
                    "recordUnreadable",
                    "Session storage is unavailable or unsafe",
                )
            })?;
            let snapshot = session_cleanup_snapshot(configuration, path, active_session_ids)?;
            let preview = snapshot.preview(&uuid()?, now, now + 600.0)?;
            self.root
                .private_child(PREVIEWS)
                .map_err(|_| failure("recordUnreadable", "Session cleanup store is unavailable"))?;
            let records = SessionCleanupRecords::open(&self.path.join(PREVIEWS), &self.root, lock)?;
            records.create(preview.clone(), now)?;
            Ok(preview)
        })
    }

    pub(super) fn with_session_configuration<T>(
        &self,
        action: impl FnOnce(&[u8], &Path, &HostReadLock) -> Result<T, WireError>,
    ) -> Result<T, WireError> {
        use crate::snapshot_pager::failure;
        let unavailable = |_| {
            failure(
                "recordUnreadable",
                "Session storage is unavailable or unsafe",
            )
        };
        self.root.validate_path(&self.path).map_err(unavailable)?;
        let lock = self.root.lock_document(LOCK).map_err(|error| {
            if error.kind() == io::ErrorKind::WouldBlock {
                failure("resourceConflict", "Session storage is being updated")
            } else {
                unavailable(error)
            }
        })?;
        let loaded = match self.root.read(DOCUMENT, MAXIMUM) {
            Ok(value) => value,
            Err(error) if error.kind() == io::ErrorKind::NotFound => bytes(&json!({
                "schemaVersion":"arkdeck.session-storage-store/1", "generation":1,
                "rootKind":"default", "rootPath":self.default_sessions,
                "policy":{"totalQuotaBytes":21474836480_u64,"safetyMarginBytes":2147483648_u64,"retentionDays":90}}))?,
            Err(error) => return Err(unavailable(error)),
        };
        let document = decode_session_configuration(&loaded)
            .map_err(|_| unavailable(io::Error::other("invalid configuration")))?;
        let path = PathBuf::from(
            document.projection["rootPath"]
                .as_str()
                .ok_or_else(|| unavailable(io::Error::other("missing root")))?,
        );
        if document.projection["rootKind"] == "default" && path != self.default_sessions {
            return Err(unavailable(io::Error::other("default root mismatch")));
        }
        let result = action(&loaded, &path, &lock)?;
        if lock.validate_link(&self.root, LOCK).is_err()
            || self.root.validate_path(&self.path).is_err()
        {
            return Err(failure(
                "outcomeUnknown",
                "Session owner changed during storage access",
            ));
        }
        Ok(result)
    }
}
