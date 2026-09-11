//! Exact Session export census with honest disclosure of unrelated unknowns.
use super::*;
use crate::snapshot_pager::failure;
use arkdeck_contract::{WireError, canonical_json, sha256_hex};

#[derive(Debug, PartialEq, Eq)]
pub struct SessionExportSnapshot {
    pub session_id: String,
    pub generation: u64,
    pub policy_generation: u64,
    pub manifest_bytes: u64,
    pub artifact_records: Vec<Value>,
    pub source: Value,
    pub catalog_status: Value,
    manifest_content: Vec<u8>,
    session_bytes: u64,
    location: [String; 3],
    census: Value,
}

pub fn session_export_snapshot(
    configuration: &[u8],
    path: &Path,
    session_id: &str,
) -> Result<SessionExportSnapshot, WireError> {
    let unreadable = |_| {
        failure(
            "recordUnreadable",
            "Session export inventory is inconsistent",
        )
    };
    if !identifier(session_id) {
        return Err(failure(
            "invalidInput",
            "Session export requires one bounded Session identity",
        ));
    }
    session_resource_rows(configuration, path, Some(session_id), None)?;
    let owner = HostDirectory::open(path).map_err(unreadable)?;
    let lock = owner.lock_document(LOCK).map_err(|error| {
        if error.kind() == io::ErrorKind::WouldBlock {
            failure("resourceConflict", "Session catalog is being updated")
        } else {
            unreadable(error)
        }
    })?;
    let root = HostDirectory::open_session_tree(path).map_err(unreadable)?;
    let root_facts = root.export_facts().map_err(unreadable)?;
    let document = catalog(&root).ok_or_else(|| unreadable(invalid()))?;
    let config = decode_session_configuration(configuration)
        .map_err(|_| unreadable(invalid()))?
        .projection;
    let generation = config["generation"]
        .as_str()
        .and_then(|s| s.parse::<u64>().ok())
        .ok_or_else(|| unreadable(invalid()))?;
    let days = config["policy"]["retentionDays"]
        .as_str()
        .and_then(|s| s.parse::<i32>().ok())
        .ok_or_else(|| unreadable(invalid()))?;
    let tree = scan(&root).map_err(unreadable)?;
    let mut unknown = tree.unknown.clone();
    let duplicate = tree.observed.len() != tree.observed.iter().collect::<BTreeSet<_>>().len();
    let mut retained = Vec::new();
    let mut used_bytes = 0_u64;
    for row in &tree.sessions {
        if let Some(entry) = document.entries.iter().find(|entry| {
            entry.session_id == row.manifest.session_id
                && session_timestamp(&entry.completed_at) == Some(row.manifest.completed_at)
        }) {
            if entry.policy_generation != generation
                || session_timestamp(&entry.expires_at)
                    != host_gregorian_add_days(row.manifest.completed_at, days)
            {
                return Err(unreadable(invalid()));
            }
            used_bytes = used_bytes
                .checked_add(row.bytes)
                .filter(|n| *n <= i64::MAX as u64)
                .ok_or_else(|| unreadable(invalid()))?;
            retained.push(row);
        } else {
            unknown.insert(row.manifest.session_id.clone());
        }
    }
    if document.generation > i64::MAX as u64
        || document.entries.iter().any(|entry| {
            !retained
                .iter()
                .any(|row| row.manifest.session_id == entry.session_id)
                && !unknown.iter().any(|reference| {
                    reference == &entry.session_id
                        || reference.ends_with(&format!("/{}", entry.session_id))
                })
        })
    {
        return Err(unreadable(invalid()));
    }
    if tree.unscoped
        || duplicate
        || (tree.incomplete && unknown.is_empty())
        || unknown.iter().any(|reference| {
            reference == session_id || reference.ends_with(&format!("/{session_id}"))
        })
    {
        return Err(failure(
            "operationUnavailable",
            "Session export cannot account for the selected identity or root layout",
        ));
    }
    let selected = retained
        .iter()
        .find(|row| row.manifest.session_id == session_id)
        .ok_or_else(|| {
            failure(
                "resourceNotFound",
                "Session is not present in the Runtime export catalog",
            )
        })?;
    let [year, month, leaf] = &selected.location;
    let session = root
        .child(year)
        .and_then(|root| root.child(month))
        .and_then(|root| root.child(leaf))
        .map_err(unreadable)?;
    let session_facts = session.export_facts().map_err(unreadable)?;
    let manifest_bytes = session
        .read("manifest.json", 16 * 1024 * 1024)
        .map_err(unreadable)?;
    let manifest = decode_manifest(&manifest_bytes).map_err(|_| unreadable(invalid()))?;
    if manifest.session_id != session_id
        || manifest.job_id != selected.manifest.job_id
        || manifest.completed_at != selected.manifest.completed_at
        || manifest.artifacts != selected.manifest.artifacts
        || session_facts.device != root_facts.device
    {
        return Err(unreadable(invalid()));
    }
    let journal_digest = session
        .optional_document_digest("journal.jsonl", 1024 * 1024 * 1024)
        .map_err(unreadable)?;
    if session
        .read("manifest.json", 16 * 1024 * 1024)
        .map_err(unreadable)?
        != manifest_bytes
        || session.export_facts().map_err(unreadable)? != session_facts
        || root.export_facts().map_err(unreadable)? != root_facts
        || measure_directory(&session).map_err(unreadable)? != selected.bytes
    {
        return Err(unreadable(invalid()));
    }
    lock.validate_link(&owner, LOCK).map_err(unreadable)?;
    root.validate_path(path).map_err(unreadable)?;
    let complete = !tree.incomplete && unknown.is_empty();
    let census = json!({"catalog":document,"currentBytes":tree.bytes,"incomplete":tree.incomplete,
        "observed":tree.observed,"unknown":unknown,"sessions":tree.sessions.iter().map(|s|json!({
            "sessionId":s.manifest.session_id,"jobId":s.manifest.job_id,"completedAt":s.manifest.completed_at,
            "artifacts":s.manifest.artifacts,"location":s.location,"bytes":s.bytes,"manifestBytes":s.manifest_bytes
        })).collect::<Vec<_>>()});
    Ok(SessionExportSnapshot {
        manifest_content: manifest_bytes.clone(),
        session_bytes: selected.bytes,
        location: selected.location.clone(),
        census,
        session_id: session_id.into(),
        generation: document.generation,
        policy_generation: generation,
        manifest_bytes: manifest_bytes.len() as u64,
        artifact_records: manifest.artifacts,
        source: json!({"jobId":manifest.job_id,"manifestSha256":sha256_hex(&manifest_bytes),"journalSha256":journal_digest,
            "rootDevice":root_facts.device.to_string(),"rootInode":root_facts.inode.to_string(),"volumeIdentity":root_facts.volume_identity,
            "sessionDevice":session_facts.device.to_string(),"sessionInode":session_facts.inode.to_string()}),
        catalog_status: json!({"complete":complete,"unaccountedSessionCount":unknown.len().to_string(),"measurementIncomplete":!complete,
            "usedBytes":used_bytes.to_string(),"blocker":if complete {Value::Null} else {json!("unaccountedSessionContent")}}),
    })
}

impl SessionExportSnapshot {
    pub fn preview(
        &self,
        preview_id: &str,
        created_at: f64,
        expires_at: f64,
        destination: Value,
        allow_sensitive: bool,
    ) -> Result<Value, WireError> {
        let invalid = || {
            failure(
                "recordUnreadable",
                "Session export projection is inconsistent",
            )
        };
        let plain = |at| {
            host_gregorian_timestamp(at)
                .map(|s| format!("{}Z", s.split('.').next().unwrap_or(&s)))
                .ok_or_else(invalid)
        };
        if !created_at.is_finite() || !expires_at.is_finite() || expires_at <= created_at {
            return Err(invalid());
        }
        let mut estimated = self.manifest_bytes;
        let mut artifacts = self.artifact_records.iter().collect::<Vec<_>>();
        artifacts.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
        let artifacts = artifacts.into_iter().map(|artifact| {
            let role = artifact["role"].as_str().ok_or_else(invalid)?;
            let bytes = artifact["size"].as_u64().ok_or_else(invalid)?;
            let sensitive = ["raw","partial"].contains(&role);
            let included = allow_sensitive || !sensitive;
            if included { estimated = estimated.checked_add(bytes).ok_or_else(invalid)?; }
            Ok(json!({"artifactId":artifact["id"],"artifactDigest":artifact["sha256"],"byteCount":bytes.to_string(),"role":role,
                "privacy":if sensitive {"sensitive"} else {"unknown"},"disposition":if included {"include"} else {"excludeByDefault"},
                "transformation":if included {"redactDeviceIdentifiers"} else {"excluded"}}))
        }).collect::<Result<Vec<_>, WireError>>()?;
        let mut value = json!({"schemaVersion":"arkdeck.session-export-preview/1","previewId":preview_id,"digestAlgorithm":"sha256-jcs",
            "sessionId":self.session_id,"generation":self.generation.to_string(),"policyGeneration":self.policy_generation.to_string(),
            "createdAtUtc":plain(created_at)?,"expiresAtUtc":plain(expires_at)?,"confirmationRequired":true,"allowSensitive":allow_sensitive,
            "sensitiveDefaultExcluded":true,"deviceIdentifierPolicy":"redact","estimatedBytes":estimated.to_string(),"destination":destination,
            "source":self.source,"catalogStatus":self.catalog_status,"artifacts":artifacts,"newDispatchCount":0});
        value["previewDigest"] = json!(sha256_hex(&canonical_json(&value).map_err(|_| invalid())?));
        Ok(value)
    }
}

impl SessionExportSnapshot {
    /// Materialize only inside a fresh private export staging directory. The
    /// durable owner must mark applying first, then compare fresh snapshots
    /// before and after publishing this returned stage.
    pub fn stage_export(
        &self,
        root_path: &Path,
        destination: &Value,
        allow_sensitive: bool,
    ) -> Result<arkdeck_platform::ExportStaging, WireError> {
        use crate::{ExportArtifactMeasurement, PreparedSessionExport};
        use arkdeck_platform::{ExportStaging, HostDirectoryFacts};
        let refused = |e: io::Error| {
            failure(
                match e.kind() {
                    io::ErrorKind::StorageFull => "quotaExceeded",
                    io::ErrorKind::Unsupported => "operationUnavailable",
                    _ => "recordUnreadable",
                },
                "Session export was refused before publication",
            )
        };
        let malformed = || refused(invalid());
        let root = HostDirectory::open_session_tree(root_path).map_err(refused)?;
        let mut session = root.child(&self.location[0]).map_err(refused)?;
        session = session.child(&self.location[1]).map_err(refused)?;
        session = session.child(&self.location[2]).map_err(refused)?;
        let session_path = self
            .location
            .iter()
            .fold(root_path.to_owned(), |p, s| p.join(s));
        self.check_export_source(&root, root_path, &session, &session_path)?;
        let prepared =
            PreparedSessionExport::new(&self.manifest_content, allow_sensitive).map_err(refused)?;
        let target = Path::new(destination["path"].as_str().ok_or_else(malformed)?);
        let parent = target.parent().ok_or_else(malformed)?;
        let name = target
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or_else(malformed)?;
        let number = |key: &str| {
            destination[key]
                .as_str()
                .and_then(|s| s.parse::<u64>().ok())
                .ok_or_else(malformed)
        };
        let expected = HostDirectoryFacts {
            device: number("parentDevice")?,
            inode: number("parentInode")?,
            volume_identity: destination["volumeIdentity"]
                .as_str()
                .ok_or_else(malformed)?
                .to_owned(),
        };
        if destination["expectedState"] != "absent" {
            return Err(malformed());
        }
        let maximum = prepared
            .maximum_growth_bytes()
            .map_err(|_| failure("quotaExceeded", "Session export write bound overflowed"))?;
        let mut stage = ExportStaging::create(parent, name, &expected, maximum).map_err(refused)?;
        let mut measurements = Vec::new();
        for artifact in prepared.artifacts() {
            let source = &artifact.source;
            let id = source["id"].as_str().ok_or_else(malformed)?;
            let path = source["relativePath"].as_str().ok_or_else(malformed)?;
            let components: Vec<_> = path.split('/').collect();
            let file_name = *components.last().ok_or_else(malformed)?;
            // Open the first ancestor directly from the retained Session;
            // files directly under its root need no duplicate/reopen API.
            let mut directory = None;
            let mut source_path = session_path.clone();
            for component in &components[..components.len() - 1] {
                let next = directory
                    .as_ref()
                    .unwrap_or(&session)
                    .child(component)
                    .map_err(refused)?;
                source_path.push(component);
                directory = Some(next);
            }
            let source_directory = directory.as_ref().unwrap_or(&session);
            source_directory
                .validate_path(&source_path)
                .map_err(refused)?;
            let (size, digest) = if prepared.requires_payload_redaction() {
                let original = source_directory
                    .read(file_name, 64 * 1024 * 1024)
                    .map_err(refused)?;
                let output = prepared.redact_payload(id, &original).map_err(refused)?;
                stage
                    .write_bytes(&artifact.output_path, &output)
                    .map_err(refused)?;
                (output.len() as u64, sha256_hex(&output))
            } else {
                let size = source["size"].as_u64().ok_or_else(malformed)?;
                let digest = source["sha256"].as_str().ok_or_else(malformed)?;
                stage
                    .copy_verified(
                        source_directory,
                        file_name,
                        &artifact.output_path,
                        size,
                        digest,
                    )
                    .map_err(refused)?;
                (size, digest.to_owned())
            };
            source_directory
                .validate_path(&source_path)
                .map_err(refused)?;
            measurements.push(ExportArtifactMeasurement {
                artifact_id: id.into(),
                size,
                sha256: digest,
            });
        }
        let manifest = prepared.finish(&measurements).map_err(refused)?;
        stage
            .write_bytes("manifest.json", &manifest)
            .map_err(refused)?;
        self.check_export_source(&root, root_path, &session, &session_path)?;
        Ok(stage)
    }
    fn check_export_source(
        &self,
        root: &HostDirectory,
        root_path: &Path,
        session: &HostDirectory,
        session_path: &Path,
    ) -> Result<(), WireError> {
        let refuse = |_| {
            failure(
                "recordUnreadable",
                "Session export source changed before publication",
            )
        };
        root.validate_path(root_path).map_err(refuse)?;
        session.validate_path(session_path).map_err(refuse)?;
        let r = root.export_facts().map_err(refuse)?;
        let s = session.export_facts().map_err(refuse)?;
        // These wire members are decimal strings, not JSON numbers.
        let root_device = r.device.to_string();
        let root_inode = r.inode.to_string();
        let session_device = s.device.to_string();
        let session_inode = s.inode.to_string();
        if self.source["rootDevice"] != root_device
            || self.source["rootInode"] != root_inode
            || self.source["volumeIdentity"] != r.volume_identity
            || s.volume_identity != r.volume_identity
            || self.source["sessionDevice"] != session_device
            || self.source["sessionInode"] != session_inode
            || session
                .read("manifest.json", 16 * 1024 * 1024)
                .map_err(refuse)?
                != self.manifest_content
            || measure_directory(session).map_err(refuse)? != self.session_bytes
            || self.source["journalSha256"]
                != json!(
                    session
                        .optional_document_digest("journal.jsonl", 1024 * 1024 * 1024)
                        .map_err(refuse)?
                )
        {
            return Err(refuse(invalid()));
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
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let nonce = u128::from_le_bytes(arkdeck_platform::random_bytes().unwrap());
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("export-source-{nonce:x}"));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self(path)
        }
        fn config(&self) -> Vec<u8> {
            let mut bytes = serde_json::to_vec(&json!({"schemaVersion":"arkdeck.session-storage-store/1","generation":1,
                "rootKind":"default","rootPath":self.0,"policy":{"totalQuotaBytes":20000,"safetyMarginBytes":1000,"retentionDays":90}})).unwrap();
            bytes.push(b'\n');
            bytes
        }
        fn session(&self, id: &str) -> PathBuf {
            let path = self.0.join("2026/07").join(id);
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&path)
                .unwrap();
            let timestamp = "2026-07-01T00:00:00Z";
            let job = format!("job-{id}");
            let manifest = json!({"schemaVersion":"1.0.0","appVersion":"1.0.0-test","coreSpecBaseline":"CORE-2.0.0","platformProfile":"macos-1.0.0",
                "sessionId":id,"jobId":job,"status":"succeeded","executionMode":"simulated","executionAuthority":"standardAgent",
                "outcomeCertainty":"confirmed","sessionDisposition":"finalized","createdAt":timestamp,"completedAt":timestamp,"archivedAt":null,
                "originalTarget":{"kind":"synthetic","connectKey":null,"transport":"synthetic","identitySnapshot":{"fixture":"export-source"}},
                "bindingHistory":[{"revision":1,"connectKey":null,"transport":"synthetic","identitySnapshot":{"fixture":"export-source"},"evidence":["fixture-binding"],"confirmedBy":"simulation","channelProtection":"notApplicable"}],
                "toolchain":{"kind":"none"},"workflow":{"kind":"resourceContract","profileVersion":"1.0.0","providerIdentity":"fixture-provider","fixtureIdentity":"export-source-fixture","scenarioIdentity":"export-source-scenario"},
                "steps":[],"parameters":[],"compensations":[],"confirmations":[],"artifacts":[],"warnings":[],"failure":null,"recovery":null});
            for (name, value) in [
                ("manifest.json", manifest),
                (
                    ".session-identity.json",
                    json!({"schemaVersion":"1.0.0","sessionId":id,"jobId":job}),
                ),
            ] {
                fs::write(path.join(name), serde_json::to_vec(&value).unwrap()).unwrap();
                fs::set_permissions(path.join(name), fs::Permissions::from_mode(0o600)).unwrap();
            }
            path
        }
        fn snapshot(&self, id: &str) -> Result<SessionExportSnapshot, WireError> {
            session_export_snapshot(&self.config(), &self.0, id)
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    #[test]
    fn materializes_actual_swift_fixture_from_anchored_sources_before_publication() {
        let root = Root::new();
        let destination_root = Root::new();
        let source_bytes =
            include_bytes!("../../../tests/fixtures/session-export/swift-export-source.json");
        let expected =
            include_bytes!("../../../tests/fixtures/session-export/swift-export-result.json");
        let manifest: Value = serde_json::from_slice(source_bytes).unwrap();
        let id = manifest["sessionId"].as_str().unwrap();
        let session = root.session(id);
        fs::write(session.join("manifest.json"), source_bytes).unwrap();
        fs::write(
            session.join(".session-identity.json"),
            serde_json::to_vec(
                &json!({"schemaVersion":"1.0.0","sessionId":id,"jobId":manifest["jobId"]}),
            )
            .unwrap(),
        )
        .unwrap();
        let mut diagnostic = vec![0xff, 0];
        diagnostic.extend_from_slice(
            b"device=fixture-device serial=fixture-serial key-only-fixture-token usb real ID",
        );
        let payloads = BTreeMap::from([
            ("raw-device",b"device-raw".to_vec()), ("partial-device",b"device-partial".to_vec()),
            ("app-diagnostic",diagnostic),
            ("plan-fixture-serial",b"target fixture-device via fixture-serial and key-only-fixture-token; slot values 111111 stay bounded".to_vec()),
        ]);
        for record in manifest["artifacts"].as_array().unwrap() {
            let path = session.join(record["relativePath"].as_str().unwrap());
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, &payloads[record["id"].as_str().unwrap()]).unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        let snapshot = root.snapshot(id).unwrap();
        let target = destination_root.0.join("published");
        let destination =
            crate::session_export_destination_facts(target.to_str().unwrap(), &root.0, &root.0)
                .unwrap();
        let stage = snapshot.stage_export(&root.0, &destination, false).unwrap();
        assert!(!target.exists());
        assert_eq!(root.snapshot(id).unwrap(), snapshot);
        let output = stage.publish().unwrap();
        assert_eq!(fs::read(output.join("manifest.json")).unwrap(), expected);
        assert_eq!(
            fs::read(session.join("manifest.json")).unwrap(),
            source_bytes
        );
        for record in manifest["artifacts"].as_array().unwrap() {
            assert_eq!(
                fs::read(session.join(record["relativePath"].as_str().unwrap())).unwrap(),
                payloads[record["id"].as_str().unwrap()]
            );
        }
    }
    #[test]
    fn source_drift_refuses_before_creating_staging() {
        let root = Root::new();
        let destination_root = Root::new();
        let session = root.session("good");
        let snapshot = root.snapshot("good").unwrap();
        let target = destination_root.0.join("published");
        let destination =
            crate::session_export_destination_facts(target.to_str().unwrap(), &root.0, &root.0)
                .unwrap();
        fs::write(session.join("journal.jsonl"), b"changed Journal").unwrap();
        assert!(snapshot.stage_export(&root.0, &destination, false).is_err());
        assert_eq!(fs::read_dir(&destination_root.0).unwrap().count(), 0);
        assert_eq!(
            fs::read(session.join("journal.jsonl")).unwrap(),
            b"changed Journal"
        );
    }
    #[test]
    fn exact_snapshot_detects_unrelated_catalog_content_beyond_aggregate_counts() {
        let root = Root::new();
        root.session("good");
        let other = root.session("other");
        let before = root.snapshot("good").unwrap();
        for name in ["manifest.json", ".session-identity.json"] {
            let path = other.join(name);
            let mut value: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
            value["jobId"] = json!("bob-other");
            fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
        }
        let after = root.snapshot("good").unwrap();
        assert_eq!(before.catalog_status, after.catalog_status);
        assert_eq!(before.source, after.source);
        assert_ne!(before, after);
    }
    #[test]
    fn source_facts_bind_real_manifest_and_optional_journal_bytes() {
        let root = Root::new();
        let session = root.session("good");
        let snapshot = root.snapshot("good").unwrap();
        assert_eq!(
            snapshot.source["manifestSha256"],
            sha256_hex(&fs::read(session.join("manifest.json")).unwrap())
        );
        assert!(snapshot.source["journalSha256"].is_null());
        let journal = b"actual fixture Journal bytes\n";
        fs::write(session.join("journal.jsonl"), journal).unwrap();
        let with_journal = root.snapshot("good").unwrap();
        assert_eq!(with_journal.source["journalSha256"], sha256_hex(journal));
        assert_eq!(with_journal.catalog_status["complete"], true);
        assert_eq!(with_journal.source["jobId"], "job-good");
    }
    #[test]
    fn preview_excludes_sensitive_artifacts_by_default_and_binds_the_explicit_choice() {
        let root = Root::new();
        let session = root.session("good");
        let path = session.join("manifest.json");
        let mut manifest: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        manifest["artifacts"] = json!([
            {"id":"z-log","role":"log","origin":"fixture","relativePath":"z.log","size":3,"sha256":sha256_hex(b"log")},
            {"id":"a-raw","role":"raw","origin":"fixture","relativePath":"a.raw","size":3,"sha256":sha256_hex(b"raw")}
        ]);
        fs::write(&path, serde_json::to_vec(&manifest).unwrap()).unwrap();
        fs::write(session.join("a.raw"), b"raw").unwrap();
        fs::write(session.join("z.log"), b"log").unwrap();
        let snapshot = root.snapshot("good").unwrap();
        let output = Root::new();
        let destination = crate::session_export_destination_facts(
            output.0.join("bundle").to_str().unwrap(),
            &root.0,
            &root.0,
        )
        .unwrap();
        let now = session_timestamp("2026-09-11T00:00:00Z").unwrap();
        let id = "00000000-0000-0000-0000-000000000001";
        let safe = snapshot
            .preview(id, now, now + 600.0, destination.clone(), false)
            .unwrap();
        assert_eq!(safe["artifacts"][0]["artifactId"], "a-raw");
        assert_eq!(safe["artifacts"][0]["disposition"], "excludeByDefault");
        assert_eq!(
            safe["artifacts"][1]["transformation"],
            "redactDeviceIdentifiers"
        );
        assert_eq!(
            safe["estimatedBytes"],
            (snapshot.manifest_bytes + 3).to_string()
        );
        let sensitive = snapshot
            .preview(id, now, now + 600.0, destination, true)
            .unwrap();
        assert_eq!(
            sensitive["estimatedBytes"],
            (snapshot.manifest_bytes + 6).to_string()
        );
        assert_ne!(safe["previewDigest"], sensitive["previewDigest"]);
        assert!(!output.0.join("bundle").exists());
        assert_eq!(fs::read(session.join("a.raw")).unwrap(), b"raw");
    }
    #[test]
    fn unrelated_registered_unreadable_session_is_disclosed_but_selected_or_unscoped_damage_refuses()
     {
        let root = Root::new();
        let good = root.session("good");
        let other = root.session("other");
        root.snapshot("good").unwrap();
        fs::write(other.join("manifest.json"), b"corrupt fixture").unwrap();
        let snapshot = root.snapshot("good").unwrap();
        assert_eq!(snapshot.catalog_status["complete"], false);
        assert_eq!(snapshot.catalog_status["unaccountedSessionCount"], "1");
        assert_eq!(
            snapshot.catalog_status["blocker"],
            "unaccountedSessionContent"
        );
        assert_eq!(
            snapshot.catalog_status["usedBytes"],
            fs::read_dir(&good)
                .unwrap()
                .map(|entry| entry.unwrap().metadata().unwrap().len())
                .sum::<u64>()
                .to_string()
        );
        assert_eq!(
            root.snapshot("other").unwrap_err().code,
            "operationUnavailable"
        );
        assert_eq!(
            session_resource_rows(&root.config(), &root.0, None, None)
                .unwrap_err()
                .code,
            "operationUnavailable"
        );
        assert_eq!(
            session_resource_rows(&root.config(), &root.0, Some("good"), Some((0, true)))
                .unwrap_err()
                .code,
            "operationUnavailable"
        );
        assert_eq!(
            crate::session_cleanup_snapshot(&root.config(), &root.0, &BTreeSet::new())
                .unwrap_err()
                .code,
            "operationUnavailable"
        );
        fs::write(root.0.join("unscoped"), b"unknown").unwrap();
        assert_eq!(
            root.snapshot("good").unwrap_err().code,
            "operationUnavailable"
        );
        assert_eq!(
            fs::read(other.join("manifest.json")).unwrap(),
            b"corrupt fixture"
        );
    }
}
