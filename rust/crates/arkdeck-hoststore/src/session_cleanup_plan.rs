//! Pure retention planning. Selection alone grants no permission to delete:
//! the owner must persist the preview, revalidate the catalog and active leases,
//! and durably enter applying before any anchored filesystem mutation.
use crate::{session_manifest::identifier, snapshot_pager::failure};
use arkdeck_contract::WireError;
use std::collections::BTreeSet;

#[derive(Debug, Clone, PartialEq)]
pub struct CleanupCandidate {
    pub session_id: String,
    pub size_bytes: u64,
    pub completed_at: f64,
    pub expires_at: f64,
    pub pinned: bool,
    pub active_lease: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub struct CleanupPlan {
    pub deletion_session_ids: Vec<String>,
    pub projected_bytes: u64,
    pub safety_target_bytes: u64,
    /// Includes active leases, treated as protected by the storage owner.
    pub pinned_bytes: u64,
    pub blocks_new_heavy_writers: bool,
}

pub fn plan_session_cleanup(
    sessions: &[CleanupCandidate],
    total_quota_bytes: u64,
    safety_margin_bytes: u64,
    now: f64,
) -> Result<CleanupPlan, WireError> {
    if !now.is_finite() {
        return Err(failure(
            "operationUnavailable",
            "Runtime clock is unavailable",
        ));
    }
    let invalid = || {
        failure(
            "recordUnreadable",
            "Session cleanup inventory or policy is malformed",
        )
    };
    if safety_margin_bytes == 0
        || total_quota_bytes <= safety_margin_bytes
        || total_quota_bytes > i64::MAX as u64
    {
        return Err(invalid());
    }
    let mut ids = BTreeSet::new();
    let (mut total, mut pinned_bytes) = (0_u64, 0_u64);
    for row in sessions {
        if !identifier(&row.session_id)
            || !ids.insert(&row.session_id)
            || !row.completed_at.is_finite()
            || !row.expires_at.is_finite()
            || row.expires_at <= row.completed_at
        {
            return Err(invalid());
        }
        total = total
            .checked_add(row.size_bytes)
            .filter(|sum| *sum <= i64::MAX as u64)
            .ok_or_else(invalid)?;
        if row.pinned || row.active_lease {
            pinned_bytes += row.size_bytes;
        }
    }
    let target = total_quota_bytes - safety_margin_bytes;
    let mut candidates = sessions
        .iter()
        .filter(|row| !row.pinned && !row.active_lease)
        .collect::<Vec<_>>();
    candidates.sort_by(|a, b| {
        (b.expires_at <= now)
            .cmp(&(a.expires_at <= now))
            .then_with(|| {
                a.completed_at
                    .partial_cmp(&b.completed_at)
                    .expect("finite dates validated")
            })
            .then_with(|| a.session_id.cmp(&b.session_id))
    });
    let mut projected = total;
    let mut deletion_session_ids = Vec::new();
    for row in candidates {
        if projected <= target {
            break;
        }
        deletion_session_ids.push(row.session_id.clone());
        projected -= row.size_bytes;
    }
    Ok(CleanupPlan {
        deletion_session_ids,
        projected_bytes: projected,
        safety_target_bytes: target,
        pinned_bytes,
        blocks_new_heavy_writers: projected > target,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn candidate(
        id: &str,
        bytes: u64,
        completed: f64,
        expires: f64,
        pinned: bool,
        active: bool,
    ) -> CleanupCandidate {
        CleanupCandidate {
            session_id: id.into(),
            size_bytes: bytes,
            completed_at: completed,
            expires_at: expires,
            pinned,
            active_lease: active,
        }
    }
    #[test]
    fn expiry_is_priority_under_pressure_not_automatic_age_deletion() {
        let rows = [
            candidate("old", 40, 1.0, 200.0, false, false),
            candidate("expired", 40, 2.0, 90.0, false, false),
        ];
        assert!(
            plan_session_cleanup(&rows, 100, 10, 100.0)
                .unwrap()
                .deletion_session_ids
                .is_empty()
        );
        let plan = plan_session_cleanup(&rows, 70, 10, 100.0).unwrap();
        assert_eq!(plan.deletion_session_ids, ["expired"]);
        assert_eq!(plan.projected_bytes, 40);
        assert!(!plan.blocks_new_heavy_writers);
    }
    #[test]
    fn pinned_and_active_sessions_survive_even_when_the_target_cannot_be_met() {
        let rows = [
            candidate("pinned", 60, 1.0, 2.0, true, false),
            candidate("active", 60, 1.0, 2.0, false, true),
            candidate("other", 10, 1.0, 2.0, false, false),
        ];
        let plan = plan_session_cleanup(&rows, 110, 10, 100.0).unwrap();
        assert_eq!(plan.deletion_session_ids, ["other"]);
        assert_eq!(plan.pinned_bytes, 120);
        assert_eq!(plan.projected_bytes, 120);
        assert!(plan.blocks_new_heavy_writers);
    }
    #[test]
    fn equal_dates_have_stable_identity_order_and_expiry_boundary_is_inclusive() {
        let rows = [
            candidate("z", 30, 1.0, 10.0, false, false),
            candidate("a", 30, 1.0, 10.0, false, false),
        ];
        let plan = plan_session_cleanup(&rows, 40, 10, 10.0).unwrap();
        assert_eq!(plan.deletion_session_ids, ["a"]);
        assert_eq!(plan.projected_bytes, 30);
    }
    #[test]
    fn ambiguous_identity_unrepresentable_totals_and_missing_clock_refuse_a_plan() {
        let row = candidate("one", 1, 1.0, 10.0, false, false);
        assert_eq!(
            plan_session_cleanup(&[row.clone(), row.clone()], 100, 10, 20.0)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        let huge = candidate("huge", i64::MAX as u64, 1.0, 10.0, false, false);
        assert_eq!(
            plan_session_cleanup(&[huge, row.clone()], 100, 10, 20.0)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert_eq!(
            plan_session_cleanup(&[row], 100, 10, f64::NAN)
                .unwrap_err()
                .code,
            "operationUnavailable"
        );
    }
}
