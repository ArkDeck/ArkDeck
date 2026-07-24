# TASK-RKFUI-001 identity-separation preflight — 2026-07-24

## Classification

- Executor: `agent`
- Evidence class: `hostOnlyBlockedPreflight`
- Protected-main base:
  `73b46b684b27eda23cfbaad06c5b707bff39e2cc`
- Authority evaluated: CHG-2026-026 proposal r2 / TASK-RKFUI-001 tool identity
  remediation, merged by PR #440
- Device/HDC commands: `0`
- `rkdeveloptool ld` dispatch: `0`
- `rkdeveloptool -v` host identity query: `1`
- E1 device mutation: `0`
- E2/destructive dispatch: `0`
- `sudo`/helper/driver/system-rule/ACL/group mutation: `0`

The implementation draft remained in an unpushed local worktree. This evidence and the r3
governance documents do not contain that implementation.

## Inputs rechecked

- Clean discovery artifact:
  - version: `rkdeveloptool ver 1.32`
  - SHA-256:
    `bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923`
  - upstream commit: `304f073752fd25c854e1bcf05d8e7f925b1f4e14`
  - signature: ad-hoc/linker-signed
  - quarantine: absent
- Existing destructive identity:
  `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`
- r2 discovery source/test/probe/registry blobs matched all four readiness pins before
  editing.

## Preflight change and results

The r2 draft changed only the then-approved discovery closure:

- canonical integration profile and registry;
- `RockchipDeviceDiscovery.swift`;
- bundled registry fixture;
- Python probe and signed Sandbox probe app;
- a regression requiring the clean hash throughout that closure and rejecting the old hash.

Results:

- `python3 -m unittest scripts/rockchip_e0_probe/test_probe.py`
  → `7` tests, `0` failures.
- `swift test --package-path Packages/ArkDeckKit --filter
  RockchipDeviceDiscoveryContractTests`
  → `6` tests, `0` failures.
- signed Sandbox probe build and `codesign --verify --deep --strict`
  → PASS; the App was not launched.
- `git diff --check`
  → PASS.
- `swift test --package-path Packages/ArkDeckKit`
  → FAIL: `382` tests executed, `1` skipped, `1` failure.

The sole failure was:

```text
RockchipFlashExecutionContractTests.
testAuthorizedFakeDescriptorExecutesExactClosedSequenceAndPublishesV21Manifest

terminal publication incomplete:
invalidManifest("rockchip toolchain does not match the pinned integration profile")
```

## Root cause

`RockchipDiscoveryIntegrationProfile.pinnedProduction` is not isolated to standalone E0
discovery. Protected main also consumes it from:

- `RockchipAuthorizationFacts.swift` for destructive admission facts and identity checks;
- `RockchipFlashExecutionHost.swift` for destructive process preparation, selected tool and
  manifest toolchain fields;
- authorization contract fixtures.

The locked manifest validator correctly and independently remains pinned to the old
destructive hash. Therefore:

- changing the shared constant to the clean hash violates r2's destructive boundary and
  causes the manifest contract to fail closed;
- retaining the old hash in `RockchipDeviceDiscovery.swift` violates r2's requirement that
  no old pin remain in the discovery Swift closure;
- fixing the consumer references requires paths explicitly forbidden or absent from the r2
  Allowed paths.

## Conclusion

- r2 identity values and fail-closed behavior are working as designed; the defect is the
  implementation namespace/allowed-path boundary.
- TASK-RKFUI-001 clean repin implementation is blocked pending proposal r3 maintainer merge.
- The required remediation is a D1 governance decision that separates the read-only
  discovery identity from the destructive Flash identity without changing either value or
  granting new command authority.
- No hardware conclusion is made. TASK-RKFUI-001 remains `ready`, not `done`; its signed
  Sandbox E0 receipt is still pending.
