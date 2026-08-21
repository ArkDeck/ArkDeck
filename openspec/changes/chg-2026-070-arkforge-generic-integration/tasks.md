# Tasks — CHG-2026-070

CHG-2026-070@r1 已由维护者通过 PR #1443 review/merge。TASK-AFG-001 在
本实现 PR 内进入 in-progress；Catalog/generic operation 工作保持 blocked，
并依赖 TASK-AFG-001、CHG-2026-069 merge 与 digest closure。

## TASK-AFG-001 — ArkForge Swift SDK and release bundle

- Status:in-progress（proposal #1443 已合入；本实现仍待维护者 review/merge）
- Platform: macos
- Hardware required: no
- Production reachability: ArkDeck agentd → ArkForgeClient → local daemon
- Acceptance: AFG-AC-1..3
- Review boundary:`CHG-2026-070-arkforge-generic-integration@r1` was merged by
  PR #1443. This implementation PR contains no catalog or generic-operation
  change and becomes protected-main behavior only after maintainer review.
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - 本 change `**`
- Forbidden: capability/admission/journal/recovery semantics

Deliver the cross-language SDK, byte-identical golden frames, validated bundle
manifest, one-key LaunchAgent configuration and legacy receipt migration.

## TASK-AFG-002 — Generic operation and alias cutover

- Status: blocked (TASK-AFG-001, CHG-2026-069 and proposal merge)
- Platform: macos
- Hardware required: no for contract stage; yes for final cutover
- Golden Journey: GJ-4
- Acceptance: AFG-AC-4..8
- Allowed paths: `Catalog/**`, generated catalog, Core operation identity,
  ArkForge flash adapter/runtime/facade/history/recovery consumers and tests,
  this change directory
- Forbidden: raw RockUSB commands/addresses in ArkDeck production lowering;
  changes to permit integrity, durable single-use or recovery classification

Publish `flash.full-restore@1`, retain `flash.dayu200` only as a compatibility
alias to the same adapter, switch new UI requests and remove literal branching
from production consumers.

## TASK-AFG-003 — Real-device cutover

- Status: blocked (TASK-AFG-002)
- Platform: macos
- Hardware required: yes, DAYU200
- Golden Journey: GJ-4
- Acceptance: AFG-AC-9

Run canonical and alias plan-parity checks against the same artifact/target,
then one canonical full restore with postflight verification. Record exact
catalog/bundle/toolchain digests. Do not replay a destructive alias job merely
to prove naming parity.
