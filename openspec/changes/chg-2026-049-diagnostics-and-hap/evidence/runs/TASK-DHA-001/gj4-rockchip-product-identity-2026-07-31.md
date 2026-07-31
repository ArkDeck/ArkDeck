# GJ-4 Rockchip installed product identity — 2026-07-31

- Base: `main@728b6c7059014f556be204c1fbdb088181c00934`
- Delivery: existing `TASK-DHA-001` product follow-up; no new change, task,
  readiness, Acceptance ID, evidence schema or governance state.
- Duplicate check: historical `TASK-BRC-004` was not reactivated. The only
  open PR at the start of this delivery was unrelated PR #848.

## Product result

The production route previously compared the product component with two
incompatible file SHA-256 identities: the historical externally built binary
used in hardware verification, and a one-time Developer ID signed and
timestamped product binary. A secure timestamp changes the final signed bytes,
so hard-coding that signed file hash also made a future release build
permanently unavailable.

This delivery:

1. discovers `rkdeveloptool` only at fixed ArkDeck product locations: beside
   the running product executable, `/Applications/ArkDeck.app/Contents/MacOS`,
   or the same path below the current user's `Applications` directory;
2. validates the nested executable with Security.framework using the exact
   product signing identifier `com.arkdeck.desktop.rkdeveloptool`, Team ID
   `8AQTYW5FKR`, Developer ID trust anchor, strict all-architecture validation,
   hardened runtime, secure timestamp and the exact reviewed child
   entitlements;
3. computes the actual installed signed-file SHA-256 and binds it through
   target facts, the materialized typed plan, E2 exact-plan capability lookup
   and the final process descriptor/recheck;
4. keeps the historical external executable identity separate. A plan carrying
   that old identity is refused before any process host action;
5. allows `operation.list` to re-evaluate an installed component instead of
   caching a startup-only Provider rejection, and reports a single actionable
   availability reason.

There is no PATH, environment, bookmark or caller-selected executable fallback.
The exact-SHA initializer remains package-internal test infrastructure and is
not part of production composition.

## Verification

Commands and results:

```text
swift test --package-path Packages/ArkDeckKit \
  --filter RockchipRuntimeCompositionContractTests
```

Result: 12 tests, 0 failures. Coverage includes fixed installed-product
discovery, unsigned-product refusal, wrong signed-product refusal, reviewed
identity admission, legacy-plan refusal with zero host dispatch and the
stable-target/binding/exact-plan E2 query.

```text
swift test --package-path Packages/ArkDeckKit \
  --filter 'RockchipRuntimeCompositionContractTests|AgentDaemonContractTests'
```

Result: 14 focused process/composition tests, 0 failures.

```text
CI=true swift test --package-path Packages/ArkDeckKit
```

Result: 779 tests, 1 skipped, 0 failures.

A real compiled `arkdeck-agentd` was also started with an isolated state root
and no configured HDC executable. A versioned UDS `operation.list` request
returned:

```text
flash.dayu200@1 availability=unavailable
reason=product-owned Rockchip component is unavailable:
       rkdeveloptool is missing from all fixed ArkDeck product locations
```

The reason appeared once. This host does not currently have a fresh signed
ArkDeck product installed at a fixed product location, so the result is a
truthful product blocker rather than a hardware-pass claim.

## Device/effect boundary

- DAYU200 real-device execution: not performed.
- HDC commands, RockUSB commands, USB access, E1/E2 capability creation or
  consumption, device mutation and destructive dispatch: all `0`.
- No authorization was created or reused.
- Real destructive Flash remains human-operated under `REQ-FLASH-015`.
- GJ-4 remains `BLOCKED_BY_PRODUCT_DEFECT`: the non-releasable identity model
  and installed-product discovery are fixed, but a fresh signed ArkDeck product
  package must be built and installed before the human E2 run can occur.
