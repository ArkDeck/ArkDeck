use super::*;
use crate::{SessionCleanupRecords, session_cleanup_snapshot};
use arkdeck_platform::HostReadLock;
use std::collections::BTreeSet;

const PREVIEWS: &str = "session-cleanup-previews";

/// What answers which Sessions its Jobs keep active, under its own guard: the
/// Job owner, under its activity guard (`JobStore::with_active_sessions`), or
/// a set fixed beforehand. A Session cleanup reads it under the storage lock,
/// which it takes first.
pub trait ActiveSessions {
    /// `action` over the active Sessions, under the guard that keeps them so.
    fn with_active(
        &self,
        action: &mut dyn FnMut(&BTreeSet<String>) -> Result<Value, WireError>,
    ) -> Result<Value, WireError>;
}

impl ActiveSessions for crate::JobStore {
    fn with_active(
        &self,
        action: &mut dyn FnMut(&BTreeSet<String>) -> Result<Value, WireError>,
    ) -> Result<Value, WireError> {
        self.with_active_sessions(|active| action(active))
    }
}

impl ActiveSessions for BTreeSet<String> {
    fn with_active(
        &self,
        action: &mut dyn FnMut(&BTreeSet<String>) -> Result<Value, WireError>,
    ) -> Result<Value, WireError> {
        action(self)
    }
}

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
        self.with_waited_session_configuration(|configuration, path, lock| {
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

    /// Swift `previewSessionCleanup`: under the storage lock, which it waits
    /// for as Swift's `withLockedDocument` does, and then, never before it,
    /// under the guard `active` keeps its Sessions active by.
    pub fn preview_cleanup(
        &self,
        active: &dyn ActiveSessions,
        now: f64,
    ) -> Result<Value, WireError> {
        use crate::snapshot_pager::{failure, uuid};
        if !now.is_finite() {
            return Err(failure(
                "operationUnavailable",
                "Runtime clock is unavailable",
            ));
        }
        self.with_waited_session_configuration(|configuration, path, lock| {
            active.with_active(&mut |active_session_ids| {
                self.selected_root(path).map_err(|_| {
                    failure(
                        "recordUnreadable",
                        "Session storage is unavailable or unsafe",
                    )
                })?;
                let snapshot = session_cleanup_snapshot(configuration, path, active_session_ids)?;
                let preview = snapshot.preview(&uuid()?, now, now + 600.0)?;
                self.root.private_child(PREVIEWS).map_err(|_| {
                    failure("recordUnreadable", "Session cleanup store is unavailable")
                })?;
                let records =
                    SessionCleanupRecords::open(&self.path.join(PREVIEWS), &self.root, lock)?;
                records.create(preview.clone(), now)?;
                Ok(preview)
            })
        })
    }

    /// Swift `applySessionCleanup`, under the storage lock and then the
    /// guard of `active`, as the preview.
    pub fn apply_cleanup(
        &self,
        preview_id: &str,
        preview_digest: &str,
        active: &dyn ActiveSessions,
        clock: impl Fn() -> f64,
    ) -> Result<Value, WireError> {
        self.apply_cleanup_with_checkpoint(preview_id, preview_digest, active, clock, |_| Ok(()))
    }

    fn apply_cleanup_with_checkpoint(
        &self,
        preview_id: &str,
        preview_digest: &str,
        active: &dyn ActiveSessions,
        clock: impl Fn() -> f64,
        checkpoint: impl Fn(&str) -> Result<(), WireError>,
    ) -> Result<Value, WireError> {
        use crate::{
            CleanupState, session_inventory::CleanupTransaction, session_time::session_timestamp,
            snapshot_pager::failure,
        };
        let stale = || {
            failure(
                "resourceConflict",
                "Session cleanup preview expired or its facts changed",
            )
        };
        let unknown = || {
            failure(
                "outcomeUnknown",
                "Session cleanup may have changed storage; this preview cannot be retried",
            )
        };
        let exact = || {
            failure(
                "invalidInput",
                "Session cleanup apply requires an exact preview tuple",
            )
        };
        if !crate::session_cleanup_records::uuid(preview_id)
            || !crate::session_manifest::hash(preview_digest)
        {
            return Err(exact());
        }
        self.with_waited_session_configuration(|configuration, path, lock| active.with_active(&mut |active| {
            if !active.iter().all(|id| crate::session_manifest::identifier(id)) {
                return Err(exact());
            }
            self.root.private_child(PREVIEWS).map_err(|_| failure("recordUnreadable", "Session cleanup store is unavailable"))?;
            let records = SessionCleanupRecords::open(&self.path.join(PREVIEWS), &self.root, lock)?;
            let record = records.load(preview_id)?;
            if record.preview_digest != preview_digest { return Err(stale()); }
            if record.state == CleanupState::Applied { return Ok(record.result); }
            if record.state != CleanupState::Ready { return Err(unknown()); }
            let now = clock();
            if !now.is_finite() { return Err(failure("operationUnavailable", "Runtime clock is unavailable")); }
            let created = record.preview["createdAtUtc"].as_str().and_then(session_timestamp).ok_or_else(stale)?;
            let expires = record.preview["expiresAtUtc"].as_str().and_then(session_timestamp).filter(|at| *at > now).ok_or_else(stale)?;
            self.selected_root(path).map_err(|_| failure("recordUnreadable", "Session storage is unavailable or unsafe"))?;
            let transaction = CleanupTransaction::open(configuration, path, active)?;
            let current = transaction.snapshot.preview(preview_id, created, expires)?;
            if current != record.preview { return Err(stale()); }
            let ids = current["sessions"].as_array().ok_or_else(stale)?.iter()
                .filter(|row| row["disposition"] == "reclaim")
                .map(|row| row["sessionId"].as_str().map(str::to_owned).ok_or_else(stale))
                .collect::<Result<BTreeSet<_>, _>>()?;
            if !ids.is_empty() && transaction.snapshot.generation == i64::MAX as u64 { return Err(stale()); }
            let removals = transaction.prepare(&ids)?;
            transaction.revalidate(&removals)?;
            let applying = records.mark_applying(&record)?;
            checkpoint("applying").map_err(|_| unknown())?;
            if let Err(error) = transaction.revalidate(&removals) {
                records.restore_ready_after_stale_snapshot(&applying).map_err(|_| unknown())?;
                return Err(error);
            }
            let after = transaction.remove(&ids, removals)?;
            checkpoint("removed").map_err(|_| unknown())?;
            let mut removed_artifacts = Vec::new();
            for row in current["sessions"].as_array().ok_or_else(unknown)? {
                if row["disposition"] != "reclaim" { continue; }
                for artifact in row["artifacts"].as_array().ok_or_else(unknown)? {
                    removed_artifacts.push(json!({"sessionId":row["sessionId"], "artifactId":artifact["artifactId"], "artifactDigest":artifact["artifactDigest"]}));
                }
            }
            let applied_at = arkdeck_platform::host_gregorian_timestamp(clock()).map(|at| format!("{}Z", at.split('.').next().unwrap_or(&at))).ok_or_else(unknown)?;
            let result = json!({"schemaVersion":"arkdeck.session-cleanup-result/1", "previewId":preview_id,
                "previewDigest":preview_digest, "generation":current["generation"], "resultGeneration":after.generation.to_string(),
                "appliedAtUtc":applied_at, "removedSessionIds":ids, "removedArtifacts":removed_artifacts,
                "reclaimedBytes":current["reclaimBytes"], "remainingBytes":after.current_bytes.to_string(), "newDispatchCount":0});
            records.mark_applied(&applying, result.clone()).map_err(|_| unknown())?;
            Ok(result)
        }))
    }

    /// A Session export or cleanup under the storage lock, which it waits
    /// for, as Swift's do under `withLockedDocument`. A cleanup takes the Job
    /// activity guard only under it: nothing holding that guard waits for
    /// the storage lock.
    pub(super) fn with_waited_session_configuration<T>(
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
        let lock = self.root.wait_lock(LOCK, false).map_err(unavailable)?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
    };
    struct Fixture {
        root: PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            Self::with_ids(&[])
        }
        fn with_ids(ids: &[&str]) -> Self {
            let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "cleanup-owner-{:032x}",
                u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
            ));
            for name in ["state", "sessions"] {
                fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(root.join(name))
                    .unwrap();
            }
            let fixture = Self { root };
            fixture.add("session-target");
            for id in ids {
                fixture.add(id);
            }
            fixture.store().handle("runtime.storage.policy", &json!({"expectedGeneration":"1", "totalQuotaBytes":"1024", "safetyMarginBytes":"1023", "retentionDays":"1"}).as_object().unwrap().clone()).unwrap();
            fixture
        }
        fn add(&self, id: &str) -> PathBuf {
            let mut manifest: Value = serde_json::from_slice(include_bytes!(
                "../../../tests/fixtures/session-export/swift-derived-source.json"
            ))
            .unwrap();
            manifest["sessionId"] = json!(id);
            manifest["jobId"] = json!(format!("job-{id}"));
            let path = self.session(id);
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&path)
                .unwrap();
            let write = |path: PathBuf, bytes: &[u8]| {
                fs::write(&path, bytes).unwrap();
                fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
            };
            write(
                path.join("manifest.json"),
                &serde_json::to_vec(&manifest).unwrap(),
            );
            write(
                path.join(".session-identity.json"),
                &serde_json::to_vec(
                    &json!({"schemaVersion":"1.0.0", "sessionId":id, "jobId":manifest["jobId"]}),
                )
                .unwrap(),
            );
            for artifact in manifest["artifacts"].as_array().unwrap() {
                let target = path.join(artifact["relativePath"].as_str().unwrap());
                fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(target.parent().unwrap())
                    .unwrap();
                write(
                    target,
                    if artifact["id"] == "export-raw" {
                        b"raw-device-trace"
                    } else {
                        b"filtered-diagnostic-trace"
                    },
                );
            }
            path
        }
        fn session(&self, id: &str) -> PathBuf {
            self.root.join("sessions/2026/07").join(id)
        }
        fn store(&self) -> SessionStore {
            SessionStore::open(&self.root.join("state"), &self.root.join("sessions")).unwrap()
        }
        fn preview(&self, active: &BTreeSet<String>) -> Value {
            self.store().preview_cleanup(active, now()).unwrap()
        }
        fn apply(
            &self,
            preview: &Value,
            active: &BTreeSet<String>,
            clock: impl Fn() -> f64,
        ) -> Result<Value, WireError> {
            self.store().apply_cleanup(
                preview["previewId"].as_str().unwrap(),
                preview["previewDigest"].as_str().unwrap(),
                active,
                clock,
            )
        }
        fn record_path(&self, preview: &Value) -> PathBuf {
            self.root
                .join("state/session-cleanup-previews")
                .join(format!(
                    "cleanup-{}.json",
                    preview["previewId"].as_str().unwrap()
                ))
        }
        fn record(&self, preview: &Value) -> Value {
            serde_json::from_slice(&fs::read(self.record_path(preview)).unwrap()).unwrap()
        }
        fn checkpoint(
            &self,
            preview: &Value,
            action: impl Fn(&str) -> Result<(), WireError>,
        ) -> Result<Value, WireError> {
            self.store().apply_cleanup_with_checkpoint(
                preview["previewId"].as_str().unwrap(),
                preview["previewDigest"].as_str().unwrap(),
                &BTreeSet::new(),
                now,
                action,
            )
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    fn now() -> f64 {
        crate::session_time::session_timestamp("2026-09-11T00:00:00Z").unwrap()
    }
    fn fault() -> WireError {
        crate::snapshot_pager::failure("ioFailure", "injected fixture fault")
    }
    #[test]
    fn a_first_session_page_waiting_for_the_storage_lock_leaves_cursor_pages_readable() {
        // Swift's `listSessions` takes the storage lock for a first page
        // before its pager and reads a cursor's page under none, so a first
        // page waiting for the lock holds up no cursor.
        let fixture = Fixture::with_ids(&["session-other"]);
        let store = fixture.store();
        let list =
            |params: Value| store.handle_resource("session.list", params.as_object().unwrap());
        let first = list(json!({"pageSize": 1})).unwrap();
        let cursor = first["nextCursor"].as_str().unwrap().to_owned();
        let held = store.root.lock_document(LOCK).unwrap();
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            let list = &list;
            scope.spawn(move || sender.send(list(json!({"pageSize": 1}))).unwrap());
            assert!(
                receiver
                    .recv_timeout(std::time::Duration::from_millis(200))
                    .is_err()
            );
            let next = list(json!({"pageSize": 1, "cursor": cursor})).unwrap();
            assert_eq!(next["items"].as_array().unwrap().len(), 1);
            drop(held);
            receiver
                .recv_timeout(std::time::Duration::from_secs(30))
                .unwrap()
                .unwrap();
        });
    }
    #[test]
    fn apply_preserves_pinned_and_active_sessions_and_returns_durable_receipt_after_restart() {
        let fixture = Fixture::with_ids(&["session-pinned", "session-active"]);
        let active = BTreeSet::from(["session-active".into()]);
        let first = fixture.preview(&active);
        fixture
            .store()
            .handle_resource(
                "session.pin",
                json!({"sessionId":"session-pinned", "expectedGeneration":first["generation"]})
                    .as_object()
                    .unwrap(),
            )
            .unwrap();
        let preview = fixture.preview(&active);
        let result = fixture.apply(&preview, &active, now).unwrap();
        assert_eq!(result["removedSessionIds"], json!(["session-target"]));
        assert_eq!(result["removedArtifacts"].as_array().unwrap().len(), 2);
        assert_eq!(result["reclaimedBytes"], preview["reclaimBytes"]);
        assert_eq!(result["remainingBytes"], preview["projectedBytes"]);
        assert_eq!(
            result["resultGeneration"]
                .as_str()
                .unwrap()
                .parse::<u64>()
                .unwrap(),
            preview["generation"]
                .as_str()
                .unwrap()
                .parse::<u64>()
                .unwrap()
                + 1
        );
        assert_eq!(result["newDispatchCount"], 0);
        assert!(!fixture.session("session-target").exists());
        assert!(fixture.session("session-active").exists());
        assert!(fixture.session("session-pinned").exists());
        assert_eq!(fixture.record(&preview)["state"], "applied");
        assert_eq!(fixture.record(&preview)["result"], result);
        if let Some(path) = std::env::var_os("ARKDECK_CLEANUP_RECORD_COPY") {
            fs::copy(fixture.record_path(&preview), path).unwrap();
        }
        fs::rename(
            fixture.session("session-pinned"),
            fixture.root.join("moved-session"),
        )
        .unwrap();
        assert_eq!(
            fixture
                .apply(&preview, &BTreeSet::new(), || panic!(
                    "cached result must not reread time or delete"
                ))
                .unwrap(),
            result
        );
    }
    #[test]
    fn exact_tuple_expiry_lease_pin_and_policy_drift_refuse_before_deletion() {
        for drift in ["digest", "expiry", "lease", "pin", "policy"] {
            let fixture = Fixture::new();
            let mut preview = fixture.preview(&BTreeSet::new());
            let mut active = BTreeSet::new();
            match drift {
                "digest" => preview["previewDigest"] = json!("f".repeat(64)),
                "lease" => {
                    active.insert("session-target".into());
                }
                "pin" => {
                    fixture.store().handle_resource("session.pin", json!({"sessionId":"session-target", "expectedGeneration":preview["generation"]}).as_object().unwrap()).unwrap();
                }
                "policy" => {
                    fixture.store().handle("runtime.storage.policy", json!({"expectedGeneration":"2", "totalQuotaBytes":"2048", "safetyMarginBytes":"2047", "retentionDays":"1"}).as_object().unwrap()).unwrap();
                }
                _ => {}
            }
            let error = fixture
                .apply(&preview, &active, || {
                    now() + if drift == "expiry" { 601.0 } else { 0.0 }
                })
                .unwrap_err();
            assert_eq!(error.code, "resourceConflict", "{drift}");
            assert!(fixture.session("session-target").exists());
            assert_eq!(fixture.record(&preview)["state"], "ready");
        }
    }
    #[test]
    fn predeletion_staleness_releases_intent_only_after_proving_zero_unlinks() {
        let fixture = Fixture::new();
        let preview = fixture.preview(&BTreeSet::new());
        let error = fixture
            .checkpoint(&preview, |point| {
                if point == "applying" {
                    fs::write(
                        fixture.session("session-target").join("late-file"),
                        b"retain",
                    )
                    .unwrap();
                }
                Ok(())
            })
            .unwrap_err();
        assert_eq!(error.code, "resourceConflict");
        assert_eq!(fixture.record(&preview)["state"], "ready");
        assert!(
            fixture
                .session("session-target")
                .join("manifest.json")
                .exists()
        );
        assert_eq!(
            fs::read(fixture.session("session-target").join("late-file")).unwrap(),
            b"retain"
        );
    }
    #[test]
    fn interrupted_intent_and_missing_receipt_are_unknown_and_never_replayed() {
        for stop in ["applying", "removed"] {
            let fixture = Fixture::new();
            let preview = fixture.preview(&BTreeSet::new());
            let error = fixture
                .checkpoint(
                    &preview,
                    |point| if point == stop { Err(fault()) } else { Ok(()) },
                )
                .unwrap_err();
            assert_eq!(error.code, "outcomeUnknown");
            assert_eq!(fixture.record(&preview)["state"], "applying");
            assert_eq!(
                fixture.session("session-target").exists(),
                stop == "applying"
            );
            if stop == "removed" {
                fixture.add("session-target");
            }
            let bytes = fs::read(fixture.session("session-target").join("manifest.json")).unwrap();
            assert_eq!(
                fixture
                    .apply(&preview, &BTreeSet::new(), || panic!(
                        "unknown intent cannot enter apply"
                    ))
                    .unwrap_err()
                    .code,
                "outcomeUnknown"
            );
            assert_eq!(
                fs::read(fixture.session("session-target").join("manifest.json")).unwrap(),
                bytes
            );
        }
    }
    #[test]
    fn unsafe_content_and_root_replacement_never_delete_the_replacement_or_referenced_content() {
        let fixture = Fixture::new();
        let preview = fixture.preview(&BTreeSet::new());
        let external = fixture.root.join("unrelated");
        fs::write(&external, b"unrelated").unwrap();
        symlink(&external, fixture.session("session-target").join("link")).unwrap();
        assert!(fixture.apply(&preview, &BTreeSet::new(), now).is_err());
        assert_eq!(fs::read(&external).unwrap(), b"unrelated");
        assert_eq!(fixture.record(&preview)["state"], "ready");
        fs::remove_file(fixture.session("session-target").join("link")).unwrap();
        let error = fixture
            .checkpoint(&preview, |point| {
                if point == "applying" {
                    fs::rename(
                        fixture.root.join("sessions"),
                        fixture.root.join("old-sessions"),
                    )
                    .unwrap();
                    fs::DirBuilder::new()
                        .mode(0o700)
                        .create(fixture.root.join("sessions"))
                        .unwrap();
                }
                Ok(())
            })
            .unwrap_err();
        assert_eq!(error.code, "resourceConflict");
        assert_eq!(fixture.record(&preview)["state"], "ready");
        assert!(
            fixture
                .root
                .join("old-sessions/2026/07/session-target/manifest.json")
                .exists()
        );
        assert!(fixture.root.join("sessions").exists());
    }
    #[test]
    fn activity_protects_manifest_job_even_when_session_has_a_nondefault_name() {
        let fixture = Fixture::new();
        let active_job_session = BTreeSet::from(["session-job-session-target".into()]);
        let preview = fixture.preview(&active_job_session);
        assert_eq!(preview["sessions"][0]["reason"], "activeLease");
        let result = fixture.apply(&preview, &active_job_session, now).unwrap();
        assert_eq!(result["removedSessionIds"], json!([]));
        assert!(fixture.session("session-target").exists());
    }
    #[test]
    fn empty_cleanup_has_no_catalog_generation_change() {
        let fixture = Fixture::new();
        let active = BTreeSet::from(["session-target".into()]);
        let preview = fixture.preview(&active);
        let result = fixture.apply(&preview, &active, now).unwrap();
        assert_eq!(result["generation"], result["resultGeneration"]);
        assert_eq!(result["removedSessionIds"], json!([]));
        assert_eq!(result["reclaimedBytes"], "0");
        assert!(fixture.session("session-target").exists());
    }
}

/// A Session cleanup takes the storage lock first and the Job owner's
/// activity guard only under it (TASK-XPA-014). Nothing that holds the
/// activity guard waits for the storage lock, so the two never wait for each
/// other: each test stops one side at a hook, lets the other run into it, and
/// requires both to finish. A wait that does not end is a lock cycle, which
/// never ends by itself: the process is aborted rather than left hanging.
#[cfg(test)]
mod lock_order_tests {
    use super::*;
    use crate::{
        CapabilityStore, DeviceHolds, JobStore, MutationAuthority, SessionPublisher, StorageClaims,
        StorageProbe, StorageSnapshot, job_journal_writer::JournalWriter, job_record::JobRecord,
    };
    use std::fs;
    use std::os::unix::fs::DirBuilderExt;
    use std::sync::{Mutex, mpsc};
    use std::time::Duration;

    const JOB: &str = "4ac2c3640786ad0e831952ab62bb71bc";
    /// 2026-09-26T00:00:00Z, in seconds since 2001.
    const NOW: f64 = 1_790_380_800.0 - 978_307_200.0;

    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
            let root = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("cleanup-lock-order-{nonce:032x}"));
            for name in ["Runtime", "session-state", "Sessions", "published"] {
                fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(root.join(name))
                    .unwrap();
            }
            Self(root)
        }
        fn jobs(&self) -> JobStore {
            JobStore::open_owner(&self.0.join("Runtime")).unwrap()
        }
        fn sessions(&self) -> SessionStore {
            SessionStore::open(&self.0.join("session-state"), &self.0.join("Sessions")).unwrap()
        }
        /// The storage lock, held as another holder would hold it.
        fn hold_storage(&self) -> HostReadLock {
            HostDirectory::open(&self.0.join("session-state"))
                .unwrap()
                .lock_document(".session-storage.lock")
                .unwrap()
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// `receiver`'s answer, or the process ended.
    fn within<T>(receiver: &mpsc::Receiver<T>, what: &str) -> T {
        receiver
            .recv_timeout(Duration::from_secs(60))
            .unwrap_or_else(|_| {
                eprintln!("{what} did not finish within 60 s: the locks wait for each other");
                std::process::abort()
            })
    }

    /// Nothing from `receiver` yet: its sender is still waiting. The bound
    /// only lets an early answer arrive.
    fn still_waiting<T: std::fmt::Debug>(receiver: &mpsc::Receiver<T>, what: &str) {
        if let Ok(early) = receiver.recv_timeout(Duration::from_millis(200)) {
            panic!("{what} answered while the storage lock was held: {early:?}");
        }
    }

    /// The Job owner's active Sessions, reached under the storage lock:
    /// says so, and then waits to be told to go on before it takes the
    /// activity guard.
    struct Stopped<'a> {
        jobs: &'a JobStore,
        under_storage: Mutex<mpsc::Sender<()>>,
        go: Mutex<mpsc::Receiver<()>>,
    }
    impl ActiveSessions for Stopped<'_> {
        fn with_active(
            &self,
            action: &mut dyn FnMut(&BTreeSet<String>) -> Result<Value, WireError>,
        ) -> Result<Value, WireError> {
            let _ = self.under_storage.lock().unwrap().send(());
            let _ = self.go.lock().unwrap().recv();
            self.jobs.with_active(action)
        }
    }

    fn record() -> JobRecord {
        JobRecord::decode(include_bytes!(
            "../../../tests/fixtures/job-publication-current/published/job-record.json"
        ))
        .unwrap()
    }

    /// While a cleanup waits for the storage lock it holds no activity
    /// guard: a Job is admitted and written, and the active Sessions read,
    /// as it waits; it is answered once the lock is released.
    #[test]
    fn a_cleanup_waiting_for_the_storage_lock_holds_no_activity_guard() {
        let root = Root::new();
        let (jobs, sessions) = (root.jobs(), root.sessions());
        let held = root.hold_storage();
        let (answered, answer) = mpsc::channel();
        let (written, write) = mpsc::channel();
        std::thread::scope(|scope| {
            let held = held;
            let (jobs, sessions) = (&jobs, &sessions);
            scope.spawn(move || answered.send(sessions.preview_cleanup(jobs, NOW)));
            still_waiting(&answer, "the cleanup preview");
            scope.spawn(move || {
                let mut record = record();
                jobs.admit(&record, &"a".repeat(64)).unwrap();
                record.set_residues(1);
                jobs.persist(&record, "2026-09-26T00:00:01Z").unwrap();
                let active = jobs
                    .with_active_sessions(|active| Ok(active.len()))
                    .unwrap();
                written.send(active).unwrap();
            });
            within(&write, "a Job's admission and write");
            drop(held);
            let preview = within(&answer, "the cleanup preview").unwrap();
            assert_eq!(
                preview["schemaVersion"],
                "arkdeck.session-cleanup-preview/1"
            );
        });
    }

    /// A cleanup holding the storage lock and waiting for the activity
    /// guard, which a writer holds, while a Job reaches its Session
    /// publication, which waits for the storage lock: once the writer lets
    /// the guard go, the cleanup finishes, and then the publication.
    #[test]
    fn a_cleanup_holding_the_storage_lock_and_a_publication_both_finish() {
        struct Probe;
        impl StorageProbe for Probe {
            fn snapshot(&self, root: &HostDirectory) -> io::Result<StorageSnapshot> {
                Ok(StorageSnapshot {
                    volume_identity: root.export_facts()?.volume_identity,
                    available_bytes: u64::MAX / 4,
                    read_only: false,
                })
            }
        }
        let root = Root::new();
        let (jobs, sessions) = (root.jobs(), root.sessions());
        // The pointer oracle's tap, terminal and not yet published.
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/pointer-input/store/jobs")
            .join(format!("job-{JOB}"));
        let directory = root.0.join("published").join(format!("job-{JOB}"));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
        let journal: String = fs::read_to_string(fixture.join("journal.jsonl"))
            .unwrap()
            .lines()
            .filter(|line| !line.contains("\"kind\":\"finalized\""))
            .map(|line| format!("{line}\n"))
            .collect();
        fs::write(directory.join("journal.jsonl"), journal).unwrap();
        let mut record: Value =
            serde_json::from_slice(&fs::read(fixture.join("job-record.json")).unwrap()).unwrap();
        record
            .as_object_mut()
            .unwrap()
            .remove("sessionPublicationRecord");
        let record = JobRecord::decode(&serde_json::to_vec(&record).unwrap()).unwrap();
        let claims = StorageClaims::default();
        let publisher = SessionPublisher {
            sessions: &sessions,
            claims: &claims,
            probe: &Probe,
        };
        let (under_storage, cleanup_holds) = mpsc::channel();
        let (go, gone) = mpsc::channel();
        let stopped = Stopped {
            jobs: &jobs,
            under_storage: Mutex::new(under_storage),
            go: Mutex::new(gone),
        };
        let (writer_holds, holding) = mpsc::channel();
        let (release, released) = mpsc::channel::<()>();
        let (previewed, preview) = mpsc::channel();
        let (published, publication) = mpsc::channel();
        std::thread::scope(|scope| {
            let (release, go) = (release, go);
            let (jobs, sessions, stopped) = (&jobs, &sessions, &stopped);
            // A writer holds the activity guard.
            scope.spawn(move || {
                jobs.with_active_sessions(|_| {
                    writer_holds.send(()).unwrap();
                    let _ = released.recv();
                    Ok(())
                })
            });
            within(&holding, "the writer taking the activity guard");
            // The cleanup takes the storage lock, and runs into the guard.
            scope.spawn(move || previewed.send(sessions.preview_cleanup(stopped, NOW)));
            within(&cleanup_holds, "the cleanup taking the storage lock");
            go.send(()).unwrap();
            // The tap reaches its publication, which waits for the lock.
            let (publisher, record, directory) = (&publisher, &record, &directory);
            scope.spawn(move || {
                let mut journal = JournalWriter::open(directory, false).unwrap();
                published.send(publisher.publish(
                    record,
                    &mut journal,
                    directory,
                    "2026-09-26T00:00:01Z",
                ))
            });
            still_waiting(&publication, "the publication");
            still_waiting(&preview, "the cleanup preview");
            release.send(()).unwrap();
            let preview = within(&preview, "the cleanup preview").unwrap();
            assert_eq!(
                preview["schemaVersion"],
                "arkdeck.session-cleanup-preview/1"
            );
            let marker = within(&publication, "the publication");
            assert!(marker.get("receipt").is_some(), "{marker}");
        });
    }

    /// A cleanup holding the storage lock while a device mutation's
    /// admission waits for it to read the storage status: the cleanup takes
    /// the activity guard, which the admission does not hold, and finishes;
    /// then the admission proves the state.
    #[test]
    fn a_cleanup_holding_the_storage_lock_and_an_admission_both_finish() {
        let root = Root::new();
        let (jobs, sessions) = (root.jobs(), root.sessions());
        let capabilities = CapabilityStore::open(&root.0.join("Runtime/capabilities")).unwrap();
        let holds = DeviceHolds::default();
        let default_root = root.0.join("Runtime");
        let authority = MutationAuthority {
            default_root: &default_root,
            sessions: Some(&sessions),
            capabilities: &capabilities,
            holds: &holds,
        };
        let (under_storage, cleanup_holds) = mpsc::channel();
        let (go, gone) = mpsc::channel();
        let stopped = Stopped {
            jobs: &jobs,
            under_storage: Mutex::new(under_storage),
            go: Mutex::new(gone),
        };
        let (previewed, preview) = mpsc::channel();
        let (admitted, admission) = mpsc::channel();
        std::thread::scope(|scope| {
            let go = go;
            let (jobs, sessions, stopped, authority) = (&jobs, &sessions, &stopped, &authority);
            scope.spawn(move || previewed.send(sessions.preview_cleanup(stopped, NOW)));
            within(&cleanup_holds, "the cleanup taking the storage lock");
            scope.spawn(move || admitted.send(authority.require_state(jobs)));
            still_waiting(&admission, "the admission");
            go.send(()).unwrap();
            let preview = within(&preview, "the cleanup preview").unwrap();
            assert_eq!(
                preview["schemaVersion"],
                "arkdeck.session-cleanup-preview/1"
            );
            within(&admission, "the admission").unwrap();
        });
    }
}
