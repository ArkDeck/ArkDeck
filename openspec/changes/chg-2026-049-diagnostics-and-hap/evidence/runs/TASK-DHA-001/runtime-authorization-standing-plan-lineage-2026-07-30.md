# E1 standing authorization plan-lineage run — 2026-07-30

- Task: `TASK-DHA-001` product follow-up
- Baseline: `main@61b12b3d4abf63ae9de9135e45f608ffb8e7ec8d`
- Validation class: contract/fake for this authorization-mechanism change
- Real-device trigger: DAYU200 job
  `job-115c2c873b646750dec93b39f4b0be9b` ended `failed` with
  `outcomeUnknown=false` under PR #842 capability; GJ-3 was then paused and
  no further device command or capability use was dispatched

## Product result

- Direct E1 device debugging still requires a maintainer-approved,
  per-device Runtime Capability.
- Automatic E1 draft now emits a standing authorization envelope bound to
  stable target identity, binding revision, exact operation version, typed
  inputs, effect ceiling, validity window and use limit. Its current
  materialized plan digest remains visible as a review preview, but is no
  longer copied into the envelope as an exact-plan restriction.
- Every submit and pre-dispatch admission still requires a complete
  materialized plan digest. Every use durably records that digest and the
  full query fingerprint in its hash-linked authorization lineage.
- A separate plan-independent scope fingerprint binds operation, effect,
  stable target, binding revision and typed inputs. A confirmed E1 use may
  therefore authorize the next materialization only when that scope is
  identical.
- Same-reservation recovery remains exact-query idempotent. Pending,
  `legacyUnverified` and `outcomeUnknown` nodes still block every new
  reservation. Existing exact-plan capabilities and all E2 destructive
  capabilities remain exact-plan and fail closed.
- Pre-upgrade lineage entries without the new scope fingerprint retain the
  previous stricter exact-query behavior; the migration does not widen
  existing authorization.

## Verification

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter 'RuntimeCapabilityStoreContractTests|AgentDaemonContractTests'
# 34 tests, 0 failures

CI=true swift test --package-path Packages/ArkDeckKit \
  --filter 'RuntimeCapabilityTests|RuntimeJobEngineContractTests'
# 23 tests, 0 failures

CI=true swift test --package-path Packages/ArkDeckKit \
  --filter 'RuntimeCapabilityStoreContractTests|RuntimeJobEngineContractTests|AgentDaemonContractTests'
# 45 tests, 0 failures

CI=true swift test --package-path Packages/ArkDeckKit
# 724 tests, 1 manual sleep/wake test skipped, 0 failures
```

The full regression was run from a normal `/Users/...` worktree. A first run
from `/private/tmp` produced two known resource-relative-path fixture
failures; both affected suites passed independently and in the full normal
path run. Repository guards reported 0 errors, 0 warnings and 114 Acceptance
IDs.

## Governance and residual boundary

- No OpenSpec change, proposal, Acceptance ID, Evidence Schema, governance
  status or acceptance count was added or modified.
- This change does not make E1 unauthenticated and does not alter E2 policy.
- GJ-3 remains paused. This run validates only the authorization product
  path and does not claim a new real-device Golden Journey pass.
