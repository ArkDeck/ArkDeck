# GJ-4 Rockchip per-action Runtime host — 2026-07-31

- Base: `main@f9348064d37ad15428335cc989179e576bf8db08`
- Delivery: existing `TASK-DHA-001` product follow-up; no new change, task,
  readiness, Acceptance ID, evidence schema or governance state.
- Duplicate check: historical `TASK-BRC-004` describes this product seam. Per
  `PRODUCT-LOOP.md` §16 it remains historical and was not reactivated.

## Product result

The production Rockchip route previously remained a refusing placeholder even
if the bundled executable identity were made compatible with the destructive
profile. It had no executable per-action host, no host-level intent/receipt,
and no real partition-content readback.

This delivery:

1. carries a structured host descriptor with job, step, target, binding,
   connect key, stable identity, provider executable SHA-256 and exact typed
   action SHA-256;
2. binds the executable and action identities into the materialized plan before
   capability consumption, then revalidates both immediately before host
   dispatch;
3. registers a product-owned host for all ten published Rockchip actions;
4. emits every device-scoped HDC invocation as `-t <connectKey> ...`; HDC
   enumeration remains the host-scoped `list targets -v`;
5. writes an owner-only, fsync-backed exact-action `intent.json` before any
   child process and a correlated `receipt.json` only after semantic success;
   duplicate job/step dispatch and action-digest drift are refused;
6. stages the pinned bundle under the job/step record directory, uses only
   `ld`, `ppt`, the nine fixed-order `wlx` writes and `rd`, and treats each
   `wlx` as a non-interruptible partition boundary;
7. implements dedicated partition readback with fixed `rl` argv, 64 MiB
   job-owned chunks, exact image-prefix hashing, immediate chunk removal and
   all-nine-partition SHA-256 comparison;
8. reports the host unavailable before capability consumption when its durable
   record root or descriptor-bound HDC dependency cannot materialize;
9. preserves `outcomeUnknown` for a completed mutation whose durable receipt
   cannot be published and never supplies an automatic resend path.

The existing product compatibility gate remains unchanged and fail-closed:
bundled executable SHA-256
`9711271d3399b3915bf8ba5beb43ca5321e9eb880a47016d403f1ec358c820bc`
still differs from the hardware-verified destructive profile SHA-256
`038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`.

## Verification

Commands:

```text
swift test --package-path Packages/ArkDeckKit \
  --filter 'RockchipRuntimeCompositionContractTests|DeviceProviderContractTests|ObserveDeviceSkeletonContractTests|RuntimeJobEngineContractTests'
swift test --package-path Packages/ArkDeckKit \
  --filter RockchipRuntimeCompositionContractTests
CI=true swift test --package-path Packages/ArkDeckKit
scripts/check-sdd.sh
git diff --check
```

Results:

- Focused cross-boundary regression: 37 tests, 0 failures.
- Final Rockchip host/readback regression: 8 tests, 0 failures.
- Final full Swift suite: 775 tests, 0 failures, 1 manual sleep/wake test
  skipped.
- SDD checker: 0 errors, 0 warnings, acceptance count unchanged at 114.
- Diff check: PASS.

## Device/effect boundary

- DAYU200 real-device execution: not performed.
- Reason: production availability still rejects the incompatible bundled and
  hardware-verified executable identities before E2 consumption. Real
  destructive execution is also human-operated under `REQ-FLASH-015`.
- HDC commands, RockUSB commands, USB access, capability consumption, device
  mutation and destructive dispatch: all `0`.
- The `rl` partition readback was exercised with materializing contract
  runners, not represented as real hardware evidence.
- GJ-4 remains `BLOCKED_BY_PRODUCT_DEFECT`: this delivery closes the missing
  per-action production host; the remaining product blocker is the bundled
  Rockchip executable identity incompatibility.
