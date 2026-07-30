# GJ-4 Rockchip production composition — 2026-07-31

- Base: `main@5343c5823e5effc1a2073eb0c3f216291200ee58`
- Delivery: existing `TASK-DHA-001` product follow-up; no new change, task,
  readiness, Acceptance ID, evidence schema or governance state.
- Duplicate check: historical `TASK-BRC-004` describes the same product-owned
  composition seam. Per `PRODUCT-LOOP.md` §16 it was not reactivated, refreshed
  or used to block this product fix.

## Product result

The production daemon previously registered only HDC. Although
`flash.dayu200@1` and its complete typed Rockchip plan existed, the live
`operation.list` could only report that the provider was not registered.

This delivery:

1. registers the Rockchip Provider in `arkdeck-agentd`;
2. resolves Rockchip target facts from the same durable target record used by
   HDC, including stable identity, binding revision and connect key;
3. routes HDC and Rockchip dispatch only from `TypedProviderAction`;
4. resolves Rockchip only from the fixed product sibling
   `rkdeveloptool`, with canonical regular-executable and exact signed-byte
   identity checks; there is no PATH, bookmark, environment or caller path
   fallback;
5. publishes the next real blocker before capability consumption: bundled
   package `arkdeck-rockchip-component-package@1.0.0` has signed executable
   SHA-256
   `9711271d3399b3915bf8ba5beb43ca5321e9eb880a47016d403f1ec358c820bc`,
   while the hardware-verified destructive Flash profile remains pinned to
   `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`.

Those identities were not silently equated or repinned. `flash.dayu200@1`
therefore remains production `unavailable`, with zero process or E2 dispatch.

## Verification

Commands:

```text
swift test --package-path Packages/ArkDeckKit \
  --filter RockchipRuntimeCompositionContractTests
swift test --package-path Packages/ArkDeckKit \
  --filter AgentDaemonContractTests.testDaemonBinaryStaysAliveAndServesRequests
CI=true swift test --package-path Packages/ArkDeckKit
scripts/check-sdd.sh
git diff --check
```

Results:

- Rockchip composition contract: 4 tests, 0 failures.
- Real `arkdeck-agentd` process test: PASS; the daemon stayed alive, served
  `operation.list`, listed `flash.dayu200@1` as `unavailable`, and named the
  product-owned bundled-component blocker rather than `provider_not_registered`.
- Full Swift suite: 771 tests, 0 failures, 1 manual sleep/wake test skipped.
- SDD checker and diff check: PASS.

## Device/effect boundary

- DAYU200 real-device execution: not performed.
- Reason: product availability correctly fails before E2 authorization while
  the bundled/destructive executable identities differ. A real destructive
  Flash is additionally human-operated by `REQ-FLASH-015`; this Agent did not
  dispatch it.
- HDC commands, RockUSB commands, USB access, device mutation, destructive
  dispatch and capability consumption: all `0`.
- GJ-4 result: still `BLOCKED_BY_PRODUCT_DEFECT`; this run closes production
  provider/facts/routing registration but does not claim Flash success.
