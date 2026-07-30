# E1 standing authorization plan-lineage run — 2026-07-30

- Task: `TASK-DHA-001` product follow-up
- Baseline: `main@61b12b3d4abf63ae9de9135e45f608ffb8e7ec8d`
- Validation class: contract/fake for this authorization-mechanism change
- Real-device trigger: DAYU200 job
  `job-115c2c873b646750dec93b39f4b0be9b` ended `failed` with
  `outcomeUnknown=false` under PR #842 capability; GJ-3 was then paused and
  no further device command or capability use was dispatched

## Product result

- Direct E1 device debugging no longer requires a capability JSON,
  `capability install` command or maintainer review. When an enabled published
  operation has `standingCapability` policy and the caller supplies no
  reference, the Runtime creates and installs the capability itself only
  after Provider, target facts, Artifact leases and the complete typed plan
  materialize.
- Automatic capabilities are bound to the current Catalog digest, stable
  target identity, binding revision, exact operation version, typed inputs
  and the E1 effect ceiling. They carry a 30-day/10,000-use generation and
  renew automatically only after the previous generation is expired or
  exhausted with fully confirmed lineage.
- The persisted envelope carries the complete exact typed-input map,
  including optional-field absence. Supplying an automatic capability ID
  explicitly cannot add a boolean, optional policy or other input.
- Every submit and pre-dispatch admission still requires a complete
  materialized plan digest. Every use durably records that digest and the
  full query fingerprint in its hash-linked authorization lineage.
- A separate plan-independent scope fingerprint binds operation, effect,
  stable target, binding revision and typed inputs. A confirmed E1 use may
  therefore authorize the next materialization only when that scope is
  identical.
- Same-reservation recovery remains exact-query idempotent. Pending,
  `legacyUnverified` and `outcomeUnknown` nodes block every new reservation.
  A target/binding-level check also prevents changing typed inputs or an
  Artifact lease from selecting another automatic envelope after an unknown
  mutation.
- The runtime issuer is structurally illegal for a destructive ceiling.
  Existing exact-plan capabilities and all E2 destructive capabilities remain
  maintainer-issued, one-shot, exact-plan and fail closed.
- Pre-upgrade lineage entries without the new scope fingerprint retain the
  previous stricter exact-query behavior; the migration does not widen
  existing authorization.

## Verification

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter 'RuntimeCapabilityTests|RuntimeCapabilityStoreContractTests|RuntimeJobEngineContractTests|DiagnosticsAndHAPContractTests|AgentRuntimeExecutorContractTests|AgentDaemonContractTests'
# 110 tests, 0 failures

CI=true swift test --package-path Packages/ArkDeckKit
# commit ff93955b, normal /Users/... worktree
# 728 tests, 1 manual sleep/wake test skipped, 0 failures

scripts/check-sdd.sh
# 0 errors, 0 warnings, 114 Acceptance IDs
```

The full regression was run from a detached normal `/Users/...` worktree at
the exact implementation commit. A first run from `/private/tmp` produced
two resource-relative-path fixture failures because macOS exposed the
worktree as both `/tmp` and `/private/tmp`; the same two suites and the full
suite passed from the normal path. No product assertion was weakened.

## Governance and residual boundary

- No OpenSpec change, proposal, Acceptance ID, Evidence Schema, governance
  status or acceptance count was added or modified.
- E1 remains authenticated by the published Catalog policy and its durable
  runtime lineage, but it has no human authorization step. E2 policy is not
  altered.
- GJ-3 remains paused. This run validates only the authorization product
  path and does not claim a new real-device Golden Journey pass.
