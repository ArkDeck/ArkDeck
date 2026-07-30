# GJ-4 flash bundle Artifact import — 2026-07-30

## Product result

- Added `arkdeck artifact import-flash-bundle --target <id> --file
  <images.tar.gz>`.
- The CLI and daemon stream bounded chunks; neither side loads the pinned
  732,948,803-byte archive into one `Data` value.
- The daemon binds the upload to the adopted target snapshot and refuses a
  binding change before publication.
- Commit validates the complete gzip/tar inventory, archive/member sizes and
  SHA-256 values against the existing `dayu200@1` profile, then publishes a
  pinned ID-only `imageBundleLease`.
- Runtime resolves that lease and its target binding before authorization;
  execution-time host verification repeats the pinned profile check.

## Verification

```text
swift test --package-path Packages/ArkDeckKit \
  --filter 'RuntimeArtifactContractTests|AgentDaemonContractTests'
```

Result: 41 tests, 0 failures. The focused coverage includes chunk offset
refusal, unpinned archive-fact refusal, descriptor-backed publication,
digest-drift refusal, target-bound lease publication and lease resolution.

```text
CI=true swift test --package-path Packages/ArkDeckKit
```

Result: 764 tests, 1 skipped, 0 failures.

```text
sh scripts/check-sdd.sh
```

Result: 0 errors, 0 warnings, 114 acceptance IDs (unchanged).

No real-device command and no Rockchip dispatch was executed. The pinned
DAYU200 `images.tar.gz` was not present in the workspace, and destructive
E2 execution was not authorized. This record therefore advances GJ-4
implementation only; it does not claim `REAL_DEVICE_PASS`.

## Compatibility note

This is a direct Golden Journey product fix under `PRODUCT-LOOP.md`; the
historical blocked Rockchip tasks were not reopened or modified.
