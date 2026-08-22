# Verification — CHG-2026-070

> Change:CHG-2026-070-arkforge-generic-integration@r1
>
> Status: AFG-AC-1..8 implemented and contract-verified; AFG-AC-9 remains
> blocked on the TASK-AFG-002 macOS 26 App-owned remote file panel
> remediation review/merge and the canonical run.

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
- AFG-AC-8: the full ArkDeckKit suite passes 1487 tests with 17 environment-
  gated tests skipped and zero failures. The API baseline consumer builds, and
  `testFlashSingletonPersistedAliasKeepsRecoveryJournalSchema` proves old
  `flash.dayu200@1` records remain decode-only readable/recoverable without
  reopening that retired reference for new admission.

AFG-AC-9 is intentionally not claimed by this evidence. A mock, plan-only run
or prior digest cannot substitute for the maintainer-operated destructive run.

## Protected-main cutover preflight — 2026-08-22

- ArkDeck protected main `2f6b1979a13a5fd1d2e370db8fe78461dd78df0d`
  and ArkForge protected main `3f5b48cd7247f7e4304bb4f9d8a158f4feda5a92`
  reached `execution: ready`; the Runtime composed the
  `org.openharmony.dayu200@1.0.0` ArkForge lane against one adopted target.
- Typed artifact import pinned the supplied archive at 730783514 bytes and
  SHA-256
  `4fd35765fa75b9e2ce7c11f614144804f72efdc955a197e657014df1349ac674`.
  The imported lease and target binding revision were reused unchanged for
  both plan-only requests.
- `flash.full-restore@1` and the `flash.dayu200` compatibility alias both
  materialized 14 identical steps, plan digest
  `3a00e9737487c812676b040f04e14bf5d01071b2783a5f64bbfb5123cb7a6445`,
  and step-set digest
  `c1ab01f8c7c24649080d109c481f9c034ffb73edcc62033684ac8a59875e0b12`.
  Effect, authorization and catalog facts matched; both responses remained
  `planOnly`, `notDispatched`, and `jobAdmitted=false`.
- Runtime catalog digest was
  `7eec3b89228be6acf8be5b419f953d430a7349f38c99ee928cd261aeba7ad2a7`.
  The locally assembled manifest-valid preflight bundle pinned ArkForge CLI
  SHA-256
  `3dac10687416c3c65ac6c60173ec420ad0c70b80b1027a7194c6a643ceae254d`
  and daemon/toolchain SHA-256
  `408b9bc7520275fde0eacfa4fe63db49ba5982fbcdb9c6e3c2797dcd81853d66`.
  It was unsigned and is preflight evidence only, not release acceptance.
- PR #1455 moved the interpreted Swift XPC bridge to an exact-source,
  owner-private AOT executable; PR #1456 replaced the undocumented remote-view
  file-panel identifier with stable panel controls and workspace readback;
  PR #1457 added a role-bounded localized sidebar fallback.
- Protected-main replay proved the visible macOS 26 sidebar row's computed label
  is not present in the raw AX attributes available to the actuator. The
  validated external-candidate extension point therefore owns only the
  non-submitting Flash navigation click; archive identity, plan facts and the
  sole submit gesture remain protected-main responsibilities.
- After that navigation, the actuator opened the exact App's system file panel.
  Process and AX inspection proved macOS hosts it in
  `com.apple.appkit.xpc.openAndSavePanelService`: ArkDeck becomes inactive and
  `frontmostApplication` can be nil while the panel remains inside the exact
  ArkDeck AX tree. The prior generic frontmost guard refused before selecting
  an archive. No Runtime Job or device dispatch occurred and the debug session
  used zero destructive epochs.
- The remediation keeps ordinary input behind the exact-App frontmost guard.
  Only file-panel keystrokes and AX press may use the remote-panel path, and
  only while the exact ArkDeck process is alive, its AX tree contains the
  stable requested control plus `OKButton`, and no unrelated application owns
  the foreground.
- The modified actuator typechecks; the focused architecture-boundary contract
  passes, and the full ArkDeckKit suite passes 1487 tests with 17
  environment-gated skips and zero failures.
- Typed Runtime pagination reports no current Job. Historical unknown records
  are either superseded or carry an explicit target-alias resolution owner;
  none was replayed during this preflight.

Real-device verification must not be inferred from a mock, scripted process or
prior catalog digest. Alias execution parity is established from materialized
plans; only the canonical operation is destructively executed in this change.
