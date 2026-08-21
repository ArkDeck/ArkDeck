# Tasks — CHG-2026-070

All tasks are blocked until this proposal is reviewed and merged. Catalog work
also depends on CHG-2026-069 merge and digest closure.

## TASK-AFG-001 — ArkForge Swift SDK and release bundle

- Status: blocked (proposal review/merge)
- Platform: macos
- Hardware required: no
- Production reachability: ArkDeck agentd → ArkForgeClient → local daemon
- Acceptance: AFG-AC-1..3
- Allowed paths: `Packages/ArkDeckKit/Package.swift`, ArkForge SDK dependency
  integration, ArkForge lane composition/install sources and their tests,
  this change directory
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

