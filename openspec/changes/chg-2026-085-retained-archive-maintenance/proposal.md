---
id: CHG-2026-085-retained-archive-maintenance
revision: 1
status: proposed
class: core
core_change_level: minor
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos, windows]
---

# Preserve archived unknown Jobs across Runtime maintenance

After CHG-2026-084 archives an expired unknown Flash as `interrupted`, the Job
correctly remains in the current-job census to retain device admission blockers.
The maintenance restart predicate only permits `waitingForRecovery`, so the
completed archive prevents a safe Runtime restart, including enabling an already
registered HDC configuration on Windows.

This GJ-4 fix adds one narrowly proved maintenance carry-over case. Both platform
CLIs query the existing read-only `job.archive.preview` on the identity-verified
Runtime for each current interrupted unknown. A completed, published retained-risk
archive may survive maintenance when all existing closure constraints hold.
The pre/post comparison includes the Runtime's record-and-journal review digest.
The already published preview API also permits upgrading an older Runtime without
editing its state or needing the new daemon to run first.

No operation, provider, device profile, wire field, capability API or device
admission exception is added. Original unknown outcomes, managed-process uncertainty,
resource holds, capability lineage and expired budgets remain intact. Restart does
not prove a device safe, replay an unknown intent, stop an external HDC server or
authorize a fresh destructive operation. POL-RECOVERY-001, POL-AGENT-002 and
POL-HDC-001 continue to apply. Partial/unpublished archives remain blocked.

The implementation and [scoped delta](spec-delta.md) travel together for maintainer
review before protected-main publication. This change does not ratify a Core
baseline, mark itself approved/verified or claim hardware acceptance.
