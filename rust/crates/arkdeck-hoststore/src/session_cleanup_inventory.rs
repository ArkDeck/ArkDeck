//! Complete, locked Session census for retention previews. The caller holds
//! the configuration lock; this layer uses the catalog's pin/publication lock.
use super::*;
use crate::{CleanupCandidate, plan_session_cleanup, snapshot_pager::failure};
use arkdeck_contract::{WireError, canonical_json, sha256_hex};

#[derive(Clone, Debug, PartialEq)]
pub struct CleanupSession {
    pub candidate: CleanupCandidate,
    /// Validated manifest records retain provenance for comparison on apply.
    pub artifact_records: Vec<Value>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct CleanupSnapshot {
    pub generation: u64,
    pub policy_generation: u64,
    pub total_quota_bytes: u64,
    pub safety_margin_bytes: u64,
    pub current_bytes: u64,
    pub sessions: Vec<CleanupSession>,
}

pub fn session_cleanup_snapshot(
    configuration: &[u8],
    path: &Path,
    active_session_ids: &BTreeSet<String>,
) -> Result<CleanupSnapshot, WireError> {
    let unreadable = |_| {
        failure(
            "recordUnreadable",
            "Session cleanup inventory is inconsistent",
        )
    };
    if !active_session_ids.iter().all(|id| identifier(id)) {
        return Err(unreadable(invalid()));
    }
    // Reconcile policy and registration through the existing owner. Unknown
    // content must produce the same actionable refusal as Session discovery.
    session_resource_rows(configuration, path, None, None)?;
    let root = HostDirectory::open_session_tree(path).map_err(unreadable)?;
    let owner = HostDirectory::open(path).map_err(unreadable)?;
    let lock = owner.lock_document(LOCK).map_err(|error| {
        if error.kind() == io::ErrorKind::WouldBlock {
            failure("resourceConflict", "Session catalog is being updated")
        } else {
            unreadable(error)
        }
    })?;
    let document = catalog(&root).ok_or_else(|| unreadable(invalid()))?;
    let config = decode_session_configuration(configuration)
        .map_err(|_| unreadable(invalid()))?
        .projection;
    let number = |value: &Value| {
        value
            .as_str()
            .and_then(|s| s.parse::<u64>().ok())
            .ok_or_else(|| unreadable(invalid()))
    };
    let policy_generation = number(&config["generation"])?;
    let days = i32::try_from(number(&config["policy"]["retentionDays"])?)
        .map_err(|_| unreadable(invalid()))?;
    let tree = scan(&root).map_err(unreadable)?;
    if document.generation > i64::MAX as u64
        || tree.bytes > i64::MAX as u64
        || tree.incomplete
        || tree.unscoped
        || !tree.unknown.is_empty()
        || tree.sessions.len() != document.entries.len()
        || tree.observed.len() != tree.observed.iter().collect::<BTreeSet<_>>().len()
    {
        return Err(unreadable(invalid()));
    }
    let mut sessions = Vec::new();
    for row in tree.sessions {
        let entry = document
            .entries
            .iter()
            .find(|entry| entry.session_id == row.manifest.session_id)
            .ok_or_else(|| unreadable(invalid()))?;
        let expires_at =
            session_timestamp(&entry.expires_at).ok_or_else(|| unreadable(invalid()))?;
        if session_timestamp(&entry.completed_at) != Some(row.manifest.completed_at)
            || entry.policy_generation != policy_generation
            || host_gregorian_add_days(row.manifest.completed_at, days) != Some(expires_at)
            || row.bytes > i64::MAX as u64
        {
            return Err(unreadable(invalid()));
        }
        let active_lease = active_session_ids.contains(&row.manifest.session_id);
        sessions.push(CleanupSession {
            candidate: CleanupCandidate {
                session_id: row.manifest.session_id,
                size_bytes: row.bytes,
                completed_at: row.manifest.completed_at,
                expires_at,
                pinned: entry.is_pinned,
                active_lease,
            },
            artifact_records: row.manifest.artifacts,
        });
    }
    sessions.sort_by(|a, b| a.candidate.session_id.cmp(&b.candidate.session_id));
    lock.validate_link(&owner, LOCK).map_err(unreadable)?;
    root.validate_path(path).map_err(unreadable)?;
    Ok(CleanupSnapshot {
        generation: document.generation,
        policy_generation,
        total_quota_bytes: number(&config["policy"]["totalQuotaBytes"])?,
        safety_margin_bytes: number(&config["policy"]["safetyMarginBytes"])?,
        current_bytes: tree.bytes,
        sessions,
    })
}

impl CleanupSnapshot {
    pub fn preview(
        &self,
        preview_id: &str,
        created_at: f64,
        expires_at: f64,
    ) -> Result<Value, WireError> {
        let unreadable = || {
            failure(
                "recordUnreadable",
                "Session cleanup projection is inconsistent",
            )
        };
        let plain = |at| {
            host_gregorian_timestamp(at)
                .map(|s| format!("{}Z", s.split('.').next().unwrap_or(&s)))
                .ok_or_else(unreadable)
        };
        if self.generation > i64::MAX as u64
            || self.policy_generation > i64::MAX as u64
            || !expires_at.is_finite()
            || expires_at <= created_at
        {
            return Err(unreadable());
        }
        let candidates = self
            .sessions
            .iter()
            .map(|s| s.candidate.clone())
            .collect::<Vec<_>>();
        let plan = plan_session_cleanup(
            &candidates,
            self.total_quota_bytes,
            self.safety_margin_bytes,
            created_at,
        )?;
        let deleting = plan.deletion_session_ids.iter().collect::<BTreeSet<_>>();
        let mut current_bytes = 0_u64;
        let mut reclaim_bytes = 0_u64;
        let mut sessions = self.sessions.iter().collect::<Vec<_>>();
        sessions.sort_by(|a, b| a.candidate.session_id.cmp(&b.candidate.session_id));
        let sessions = sessions.into_iter().map(|session| {
            let row = &session.candidate;
            current_bytes = current_bytes.checked_add(row.size_bytes).ok_or_else(unreadable)?;
            let remove = deleting.contains(&row.session_id);
            if remove { reclaim_bytes = reclaim_bytes.checked_add(row.size_bytes).ok_or_else(unreadable)?; }
            let reason = if row.active_lease { "activeLease" } else if row.pinned { "pinned" }
                else if remove && row.expires_at <= created_at { "expiredQuotaPressure" }
                else if remove { "quotaPressure" } else { "withinSafetyTarget" };
            let mut artifacts = session.artifact_records.iter().collect::<Vec<_>>();
            artifacts.sort_by(|a,b| a["id"].as_str().cmp(&b["id"].as_str()));
            let artifacts = artifacts.into_iter().map(|artifact| {
                let role = artifact["role"].as_str().ok_or_else(unreadable)?;
                let bytes = artifact["size"].as_u64().ok_or_else(unreadable)?;
                let id = artifact["id"].as_str().filter(|s| identifier(s)).ok_or_else(unreadable)?;
                let digest = artifact["sha256"].as_str().filter(|s| crate::session_manifest::hash(s)).ok_or_else(unreadable)?;
                Ok(json!({"artifactId":id,"artifactDigest":digest,"byteCount":bytes.to_string(),"role":role,
                    "privacy":if ["raw","partial"].contains(&role) {"sensitive"} else {"unknown"}}))
            }).collect::<Result<Vec<_>, WireError>>()?;
            Ok(json!({"sessionId":row.session_id,"disposition":if remove {"reclaim"} else {"retain"},
                "reason":reason,"sizeBytes":row.size_bytes.to_string(),"expiresAtUtc":plain(row.expires_at)?,
                "pinned":row.pinned,"activeLease":row.active_lease,"artifacts":artifacts}))
        }).collect::<Result<Vec<_>, WireError>>()?;
        if current_bytes != self.current_bytes {
            return Err(unreadable());
        }
        let mut value = json!({"schemaVersion":"arkdeck.session-cleanup-preview/1","previewId":preview_id,
            "digestAlgorithm":"sha256-jcs","generation":self.generation.to_string(),
            "policyGeneration":self.policy_generation.to_string(),"createdAtUtc":plain(created_at)?,
            "expiresAtUtc":plain(expires_at)?,"confirmationRequired":true,"currentBytes":self.current_bytes.to_string(),
            "projectedBytes":plan.projected_bytes.to_string(),"safetyTargetBytes":plan.safety_target_bytes.to_string(),
            "reclaimBytes":reclaim_bytes.to_string(),"blocksNewHeavyWriters":plan.blocks_new_heavy_writers,
            "sessions":sessions,"newDispatchCount":0});
        value["previewDigest"] = json!(sha256_hex(
            &canonical_json(&value).map_err(|_| unreadable())?
        ));
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn session(id: &str, pinned: bool, active: bool) -> CleanupSession {
        CleanupSession {
            candidate: CleanupCandidate {
                session_id: id.into(),
                size_bytes: 100,
                completed_at: 100.0,
                expires_at: 200.0,
                pinned,
                active_lease: active,
            },
            artifact_records: vec![
                json!({"id":"z","role":"raw","size":10,"sha256":"a".repeat(64)}),
                json!({"id":"a","role":"derived","size":20,"sha256":"b".repeat(64)}),
            ],
        }
    }
    fn snapshot() -> CleanupSnapshot {
        CleanupSnapshot {
            generation: 3,
            policy_generation: 2,
            total_quota_bytes: 310,
            safety_margin_bytes: 300,
            current_bytes: 300,
            sessions: vec![
                session("pinned", true, false),
                session("active", false, true),
                session("remove", false, false),
            ],
        }
    }
    #[test]
    fn preview_binds_protected_sessions_and_sorted_artifacts_without_paths() {
        let snapshot = snapshot();
        let mut preview = snapshot
            .preview("00000000-0000-0000-0000-000000000001", 300.0, 900.0)
            .unwrap();
        assert_eq!(preview["sessions"][0]["reason"], "activeLease");
        assert_eq!(preview["sessions"][1]["reason"], "pinned");
        assert_eq!(preview["sessions"][2]["reason"], "expiredQuotaPressure");
        assert_eq!(preview["reclaimBytes"], "100");
        assert_eq!(preview["projectedBytes"], "200");
        assert_eq!(preview["blocksNewHeavyWriters"], true);
        assert_eq!(preview["sessions"][2]["artifacts"][0]["artifactId"], "a");
        assert_eq!(
            preview["sessions"][2]["artifacts"][1]["privacy"],
            "sensitive"
        );
        assert!(
            preview["sessions"][0]["artifacts"][0]
                .get("relativePath")
                .is_none()
        );
        let digest = preview
            .as_object_mut()
            .unwrap()
            .remove("previewDigest")
            .unwrap();
        assert_eq!(digest, sha256_hex(&canonical_json(&preview).unwrap()));
    }
    #[test]
    fn changed_lease_or_artifact_changes_the_bound_preview_and_inconsistent_totals_refuse() {
        let id = "00000000-0000-0000-0000-000000000001";
        let original = snapshot();
        let preview = original.preview(id, 300.0, 900.0).unwrap();
        let mut changed = original.clone();
        changed.sessions[2].candidate.active_lease = true;
        assert_ne!(
            changed.preview(id, 300.0, 900.0).unwrap()["previewDigest"],
            preview["previewDigest"]
        );
        changed = original.clone();
        changed.sessions[2].artifact_records[0]["sha256"] = json!("c".repeat(64));
        assert_ne!(
            changed.preview(id, 300.0, 900.0).unwrap()["previewDigest"],
            preview["previewDigest"]
        );
        changed.current_bytes += 1;
        assert_eq!(
            changed.preview(id, 300.0, 900.0).unwrap_err().code,
            "recordUnreadable"
        );
    }
}
