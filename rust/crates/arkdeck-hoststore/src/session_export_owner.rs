//! Durable export apply owner. The exact preview tuple is spent before staging
//! and never replayed after a possibly successful destination publication.
use super::*;
use crate::snapshot_pager::failure;
use crate::{
    CleanupState, SessionExportRecords, session_export_destination_facts, session_export_snapshot,
};
use arkdeck_platform::{ExportPublishError, host_gregorian_timestamp};

impl SessionStore {
    pub fn apply_export(
        &self,
        preview_id: &str,
        preview_digest: &str,
        clock: impl Fn() -> f64,
    ) -> Result<Value, WireError> {
        if !crate::session_cleanup_records::uuid(preview_id)
            || preview_digest.len() != 64
            || !preview_digest
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(failure(
                "invalidInput",
                "Session export apply requires an exact preview tuple",
            ));
        }
        self.with_session_configuration(|configuration,path,lock| {
            let records = SessionExportRecords::open(&self.path.join("session-export-previews"),&self.root,lock)?;
            let record = records.load(preview_id)?;
            if record.preview_digest != preview_digest { return Err(failure("resourceConflict","Session export preview digest does not match")); }
            if record.state == CleanupState::Applied { return Ok(record.result); }
            if record.state != CleanupState::Ready { return Err(failure("outcomeUnknown","Session export may already have published output")); }
            let malformed = || failure("resourceConflict","Session export preview expired or is malformed");
            let stored = &record.preview;
            let created = stored["createdAtUtc"].as_str().and_then(crate::session_time::session_timestamp).ok_or_else(malformed)?;
            let expires = stored["expiresAtUtc"].as_str().and_then(crate::session_time::session_timestamp).ok_or_else(malformed)?;
            let now = clock();
            if !now.is_finite() { return Err(failure("operationUnavailable","Runtime clock is unavailable")); }
            if expires <= now { return Err(malformed()); }
            let id = stored["sessionId"].as_str().ok_or_else(malformed)?;
            let allow = stored["allowSensitive"].as_bool().ok_or_else(malformed)?;
            let destination_path = stored["destination"]["path"].as_str().ok_or_else(malformed)?;
            self.selected_root(path)?;
            let snapshot = session_export_snapshot(configuration,path,id)?;
            let destination = session_export_destination_facts(destination_path,&self.path,path)?;
            if snapshot.preview(preview_id,created,expires,destination.clone(),allow)? != record.preview {
                return Err(failure("resourceConflict","Session export facts changed after preview"));
            }
            let applying = records.mark_applying(&record)?;
            let release = |error| {
                // A failed release leaves Applying durable and therefore still
                // blocks replay. Never replace the original known refusal.
                let _ = records.restore_ready_before_publication(&applying);
                error
            };
            let stage = snapshot.stage_export(path,&destination,allow).map_err(release)?;
            let before_publish = session_export_snapshot(configuration,path,id).map_err(release)?;
            if before_publish != snapshot {
                return Err(release(failure("resourceConflict","Session changed before its export was published")));
            }
            let published = match stage.publish() {
                Ok(path) => path,
                Err(ExportPublishError::BeforePublication(error)) => {
                    return Err(release(failure("recordUnreadable",&format!("Session export refused before publication: {error}"))));
                }
                Err(ExportPublishError::OutcomeUnknown(error)) => {
                    return Err(failure("outcomeUnknown",&format!("Session export outcome requires destination inspection: {error}")));
                }
            };
            let after = session_export_snapshot(configuration,path,id).map_err(|_| failure("outcomeUnknown","Session export published but its source cannot be revalidated"))?;
            if after != snapshot { return Err(failure("outcomeUnknown","Session changed while its export was published")); }
            let published_at = host_gregorian_timestamp(clock()).map(|s|format!("{}Z",s.split('.').next().unwrap_or(&s))).ok_or_else(||failure("outcomeUnknown","Session export published but its timestamp is unavailable"))?;
            let mut included = Vec::new();
            let mut excluded = Vec::new();
            for artifact in &snapshot.artifact_records {
                let artifact_id = artifact["id"].as_str().ok_or_else(||failure("outcomeUnknown","Session export result inventory is unavailable"))?.to_owned();
                if !allow && ["raw","partial"].iter().any(|role|artifact["role"] == *role) { excluded.push(artifact_id); }
                else { included.push(artifact_id); }
            }
            included.sort(); excluded.sort();
            let result = json!({"schemaVersion":"arkdeck.session-export-result/1","previewId":preview_id,"previewDigest":preview_digest,
                "sessionId":id,"generation":snapshot.generation.to_string(),"resultGeneration":snapshot.generation.to_string(),
                "publishedAtUtc":published_at,"exportedPath":published,"source":snapshot.source,"catalogStatus":snapshot.catalog_status,
                "sourceArtifactIds":included,"excludedArtifactIds":excluded,"deviceIdentifierPolicy":"redact","evidenceClass":"derivedExport","newDispatchCount":0});
            records.mark_applied(&applying,result.clone())?;
            Ok(result)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    };
    struct Fixture {
        root: PathBuf,
        session: PathBuf,
        id: String,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "export-owner-{:032x}",
                u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
            ));
            for child in ["state", "sessions", "output"] {
                fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(root.join(child))
                    .unwrap();
            }
            let source =
                include_bytes!("../../../tests/fixtures/session-export/swift-derived-source.json");
            let manifest: Value = serde_json::from_slice(source).unwrap();
            let id = manifest["sessionId"].as_str().unwrap().to_owned();
            let session = root.join("sessions/2026/07").join(&id);
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&session)
                .unwrap();
            fs::write(session.join("manifest.json"), source).unwrap();
            fs::write(
                session.join(".session-identity.json"),
                serde_json::to_vec(
                    &json!({"schemaVersion":"1.0.0","sessionId":id,"jobId":manifest["jobId"]}),
                )
                .unwrap(),
            )
            .unwrap();
            for artifact in manifest["artifacts"].as_array().unwrap() {
                let path = session.join(artifact["relativePath"].as_str().unwrap());
                fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(path.parent().unwrap())
                    .unwrap();
                fs::write(
                    &path,
                    if artifact["id"] == "export-raw" {
                        b"raw-device-trace".as_slice()
                    } else {
                        b"filtered-diagnostic-trace".as_slice()
                    },
                )
                .unwrap();
                fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
            }
            Self { root, session, id }
        }
        fn store(&self) -> SessionStore {
            SessionStore::open(&self.root.join("state"), &self.root.join("sessions")).unwrap()
        }
        fn target(&self) -> PathBuf {
            self.root.join("output/published")
        }
        fn preview(&self) -> Value {
            self.store()
                .preview_export(&self.id, self.target().to_str().unwrap(), false, now())
                .unwrap()
        }
        fn record(&self, preview: &Value) -> Value {
            serde_json::from_slice(
                &fs::read(
                    self.root
                        .join("state/session-export-previews")
                        .join(format!(
                            "export-{}.json",
                            preview["previewId"].as_str().unwrap()
                        )),
                )
                .unwrap(),
            )
            .unwrap()
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
    fn apply(f: &Fixture, p: &Value, clock: impl Fn() -> f64) -> Result<Value, WireError> {
        f.store().apply_export(
            p["previewId"].as_str().unwrap(),
            p["previewDigest"].as_str().unwrap(),
            clock,
        )
    }

    #[test]
    fn durable_apply_is_idempotent_after_restart_and_never_republishes_cached_result() {
        let f = Fixture::new();
        let preview = f.preview();
        let result = apply(&f, &preview, now).unwrap();
        assert_eq!(result["schemaVersion"], "arkdeck.session-export-result/1");
        assert_eq!(result["newDispatchCount"], 0);
        assert_eq!(result["sourceArtifactIds"], json!(["export-derived"]));
        assert_eq!(result["excludedArtifactIds"], json!(["export-raw"]));
        assert_eq!(f.record(&preview)["state"], "applied");
        assert_eq!(f.record(&preview)["result"], result);
        let original_inode = fs::metadata(f.target()).unwrap().ino();
        fs::rename(f.target(), f.root.join("output/moved-result")).unwrap();
        fs::rename(&f.session, f.root.join("moved-source")).unwrap();
        let again = apply(&f, &preview, || {
            panic!("cached result must not re-enter export")
        })
        .unwrap();
        assert_eq!(again, result);
        assert!(!f.target().exists());
        assert_eq!(
            fs::metadata(f.root.join("output/moved-result"))
                .unwrap()
                .ino(),
            original_inode
        );
    }
    #[test]
    fn known_prepublication_refusal_restores_preview_for_exact_retry() {
        let f = Fixture::new();
        let payload = f.session.join("artifacts/derived/export.filtered");
        let original = fs::read(&payload).unwrap();
        fs::write(&payload, vec![b'x'; original.len()]).unwrap();
        let preview = f.preview();
        assert_eq!(
            apply(&f, &preview, now).unwrap_err().code,
            "recordUnreadable"
        );
        assert_eq!(f.record(&preview)["state"], "ready");
        assert!(!f.target().exists());
        assert_eq!(fs::read_dir(f.root.join("output")).unwrap().count(), 0);
        fs::write(&payload, &original).unwrap();
        assert!(apply(&f, &preview, now).is_ok());
        assert_eq!(f.record(&preview)["state"], "applied");
        assert_eq!(fs::read(&payload).unwrap(), original);
    }
    #[test]
    fn postpublication_failure_stays_applying_and_cannot_replay() {
        use std::cell::Cell;
        let f = Fixture::new();
        let preview = f.preview();
        let calls = Cell::new(0);
        assert_eq!(
            apply(&f, &preview, || {
                let n = calls.get();
                calls.set(n + 1);
                if n == 0 { now() } else { f64::NAN }
            })
            .unwrap_err()
            .code,
            "outcomeUnknown"
        );
        assert_eq!(f.record(&preview)["state"], "applying");
        let inode = fs::metadata(f.target()).unwrap().ino();
        assert_eq!(
            apply(&f, &preview, || panic!(
                "unknown outcome must not rerun export"
            ))
            .unwrap_err()
            .code,
            "outcomeUnknown"
        );
        assert_eq!(fs::metadata(f.target()).unwrap().ino(), inode);
    }
    #[test]
    fn stale_tuple_expiry_and_destination_conflict_never_spend_preview() {
        let f = Fixture::new();
        let preview = f.preview();
        assert_eq!(
            f.store()
                .apply_export(preview["previewId"].as_str().unwrap(), &"f".repeat(64), now)
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        assert_eq!(
            apply(&f, &preview, || now() + 600.0).unwrap_err().code,
            "resourceConflict"
        );
        fs::write(f.target(), b"existing").unwrap();
        assert_eq!(
            apply(&f, &preview, now).unwrap_err().code,
            "resourceConflict"
        );
        assert_eq!(f.record(&preview)["state"], "ready");
        assert_eq!(fs::read(f.target()).unwrap(), b"existing");
    }
}
