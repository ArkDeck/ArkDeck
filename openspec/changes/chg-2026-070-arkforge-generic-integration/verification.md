# Verification — CHG-2026-070

> Change:CHG-2026-070-arkforge-generic-integration@r1
>
> Status: AFG-AC-1..8 implemented and contract-verified; AFG-AC-9 remains
> blocked on TASK-AFG-002 review/merge and a maintainer-operated DAYU200 run.

| AC | Method | Expected result |
| --- | --- | --- |
| AFG-AC-1 | ArkForge Swift golden-frame suite | Swift and Rust encode/decode the same handshake, request, plan, permit, receipt, event and error frames byte-for-byte |
| AFG-AC-2 | SDK architecture guard | SDK imports no ArkDeck module and contains no permit minting, policy, provider selection or recovery classification |
| AFG-AC-3 | bundle/LaunchAgent contract tests | one canonical bundle path composes a lane; traversal, symlink, digest/member drift, partial legacy migration and mixed bundles fail closed |
| AFG-AC-4 | generated catalog tests | `flash.full-restore@1` is published for DAYU200 with generic inputs and provider `arkforge`; generator is zero-drift |
| AFG-AC-5 | alias parity tests | legacy and canonical requests produce the same canonical adapter, semantic effect set, ArkForge plan digest and acknowledgement requirements for the same admitted facts |
| AFG-AC-6 | source/architecture guard | production consumers use `ArkForgeFlashOperation`; no alias-only Rockchip write/readback lowering exists |
| AFG-AC-7 | App contract tests | new Flash UI submissions use only `flash.full-restore@1`; operation availability and typed progress do not hard-code DAYU200 step ids |
| AFG-AC-8 | full SwiftPM + app build-for-testing | all contract/core/UI tests pass; old durable `flash.dayu200` records remain readable and recoverable |
| AFG-AC-9 | maintainer-operated DAYU200 run | canonical full restore succeeds through ArkForge, exact target rebinds, required partitions and userdata are covered, postflight build matches; evidence pins catalog/bundle/toolchain digests |

## Contract-stage evidence

- AFG-AC-1..3: TASK-AFG-001 was reviewed and merged as PR #1444; its Swift
  golden-frame, SDK boundary and one-bundle composition contracts remain green
  in the full ArkDeckKit suite.
- AFG-AC-4: `scripts/catalog_gen/test_generate.py` passes 49 tests, including
  descriptor generation, provider/alias schema and zero-drift checks.
- AFG-AC-5: `testCanonicalAndDAYU200AliasMaterializeTheSameArkForgePlan`
  proves the canonical request and compatibility alias select the same adapter,
  materialized steps, effective effect, authorization policy, acknowledgement
  requirement and ArkForge plan digest, with zero dispatch in plan-only mode.
- AFG-AC-6: `testArkForgeFullRestoreConsumersUseTheCanonicalIdentityPolicy`
  guards the single Core normalizer, forbids the retired alias adapter and
  confines the alias literal to the policy, generated descriptor and legacy
  durable fixtures.
- AFG-AC-7: Flash application contracts prove new UI requests use only
  `flash.full-restore@1`; typed progress derives phases from catalog step kinds
  without DAYU200 step-id branching.
- AFG-AC-8: the full ArkDeckKit suite passes 1473 tests with 17 environment-
  gated tests skipped and zero failures. The API baseline consumer builds, and
  `testFlashSingletonPersistedAliasKeepsRecoveryJournalSchema` proves old
  `flash.dayu200@1` records remain decode-only readable/recoverable without
  reopening that retired reference for new admission.

AFG-AC-9 is intentionally not claimed by this evidence. A mock, plan-only run
or prior digest cannot substitute for the maintainer-operated destructive run.

Real-device verification must not be inferred from a mock, scripted process or
prior catalog digest. Alias execution parity is established from materialized
plans; only the canonical operation is destructively executed in this change.
