# GJ-4 Rockchip durable recovery — 2026-07-31

- Base: `main@8df534f4214f7fe33f02a87d4390d29af04627d1`
- Delivery: existing `TASK-DHA-001` product follow-up; no new change, task,
  readiness, Acceptance ID, evidence schema or governance state.
- Duplicate check: historical `TASK-BRC-004` was not reactivated. Open PR #848
  was unrelated at the start of this delivery.

## Product result

The Rockchip Runtime host already persisted the exact typed action before
external dispatch, but two production gaps prevented durable recovery:

1. all three Rockchip mutations returned `stillUnknown` without a dedicated
   readback;
2. a readback using the original job/step record identity collided with the
   durable mutation intent, so it could not be observed independently.

This delivery:

1. materializes a deterministic, recovery-attempt-bound host record identity
   for every dedicated readback while retaining the original job, target,
   binding revision, stable identity and exact typed action;
2. maps `enterLoader` to stable-identity loader observation,
   `flashPartitions` to exact bundle readback, and `rebootToNormal` to
   descriptor-bound `waitForHDCReconnect`;
3. confirms completion only from a successful durable semantic receipt for
   that read-only action. A failed or unknown readback remains
   `stillUnknown`; it never becomes permission to resend the mutation;
4. reopens exact durable host records after process restart: a completed
   receipt is replayed without external execution, an interrupted read-only
   observation may resume, and a mutation intent without a receipt is
   `outcomeUnknown` with zero resend;
5. validates reopened intent/receipt files through `O_NOFOLLOW`, owner-only
   regular-file checks, a 1 MiB bound, exact descriptor identity, hashes,
   byte counts and bounded summary fields.

The original mutation action is never synthesized, replaced or automatically
resent during reconciliation.

## Verification

Commands and results:

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter RockchipRuntimeCompositionContractTests
```

Result: 15 tests, 0 failures. New coverage proves mutation-intent interruption
has zero resend across a new host instance, interrupted read-only readback
resumes once then replays its receipt without executor dispatch, and all three
Rockchip mutations materialize their exact dedicated read-only recovery
actions.

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter 'RuntimeJobEngineContractTests|NativeLibraryDeploymentContractTests|DeviceProviderContractTests'
```

Result: 34 tests, 0 failures. This cross-boundary set covers Runtime crash
windows, original-intent reconciliation, native mutation readback and cleanup
debt continuation.

```text
CI=true swift test --package-path Packages/ArkDeckKit
```

Result: 782 tests discovered and executed, 0 failures; 1 manual sleep/wake test
was skipped by its existing environment gate.

## Signed-product preflight

The exact unsigned GJ-4 workflow artifact was still downloadable, its bundled
Rockchip component and metadata matched the reviewed package input, and the
required Developer ID identity was present on this host. No `notarytool`
credential profile was present locally or in the repository release secrets,
so a fresh notarized product package could not be truthfully produced.

Package signing, notarization, installation and product-owned device execution
were not attempted. This is a release-input blocker, not a device
authorization request.

## Device/effect boundary

- DAYU200 real-device execution: not performed.
- HDC commands, RockUSB commands, USB access, capability creation/consumption,
  E1/E2 mutation and destructive dispatch: all `0`.
- No simulation or host contract result is claimed as hardware evidence.
- Real destructive Flash remains human-operated under `REQ-FLASH-015`.
- GJ-4 remains `BLOCKED_BY_PRODUCT_DEFECT`: durable Rockchip recovery is now
  fail-closed and restart-safe, but the fresh signed/notarized installed
  product required for the human E2 handoff is still unavailable.
