# Verification — CHG-2026-070

> Change:CHG-2026-070-arkforge-generic-integration@r1
>
> Status: planned; proposal merge approves scope, not implementation or PASS.

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

Real-device verification must not be inferred from a mock, scripted process or
prior catalog digest. Alias execution parity is established from materialized
plans; only the canonical operation is destructively executed in this change.
