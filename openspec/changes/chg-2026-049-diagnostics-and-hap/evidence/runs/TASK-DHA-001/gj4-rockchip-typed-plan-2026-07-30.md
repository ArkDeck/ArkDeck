# GJ-4 Rockchip Runtime typed plan — 2026-07-30

## Product result

- Removed the migration-only `authorizationId` input from the Rockchip
  Runtime Provider. Authorization remains owned once by Runtime E2 admission.
- Materialized every non-engine `flash.dayu200@1` step as a closed typed
  action: HDC disconnect/return, Loader observation/rebind, exact partition
  flash/readback, reset, build verification and bounded post-flash HiLog.
- Bound the destructive action to the engine-resolved Artifact lease, Artifact
  ID/path/hash/size, exact DAYU200 partition order, stable target identity and
  binding-derived connect key before capability consumption.
- Persisted and reconstructed each exact Rockchip action for durable recovery;
  an unknown mutation still has no automatic replay.
- Kept production availability fail closed. The daemon does not advertise the
  operation until a production Rockchip host dispatcher and facts resolver are
  registered.

## Verification

```text
swift test --package-path Packages/ArkDeckKit \
  --filter 'DeviceProviderContractTests|ObserveDeviceSkeletonContractTests'
```

Result: 16 tests, 0 failures. The coverage walks all ten provider-owned Catalog
steps, validates WorkflowStep journal arguments, exact-action persistence
round-trips, partition-order refusal and the current host-managed dispatcher
refusal.

```text
CI=true swift test --package-path Packages/ArkDeckKit
sh scripts/check-sdd.sh
```

Result: 767 tests, 1 skipped, 0 failures; SDD check: 0 errors and 0 warnings.
The recovery negatives also reject a persisted non-canonical Artifact path.

No HDC, RockUSB or destructive command was dispatched. This vertical product
fix advances GJ-4 plan materialization only and does not claim
`REAL_DEVICE_PASS`; E2 real-device execution still requires its exact approved
plan and a human-operated run.

## Compatibility note

This is a direct product-loop repair. No OpenSpec change, Acceptance ID,
readiness/status task or historical Rockchip task update was created.
