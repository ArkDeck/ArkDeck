# Runtime authorization envelope run — 2026-07-30

- Task: `TASK-DHA-001` product follow-up
- Baseline: `main@2bf7446770d775d22c3f13c446571ace48b7a0e9`
- Execution class: contract/fake; no real-device command or mutation was
  dispatched by this run

## Product result

- E1 `capability draft` accepts a reviewed bound of `maximumUses=1...32`;
  the default remains 1, so omission cannot silently widen authority.
- The installed capability remains the authorization envelope. Each
  consumption adds an immutable receipt and outcome history linked to the
  previous lineage digest and bound to Job, reservation, operation, effect,
  stable target identity, binding revision and typed-plan digest.
- A new reservation is admitted only after the preceding outcome is
  confirmed and the full authorization scope matches the first use.
- The same reservation is idempotent across a crash. `outcomeUnknown`,
  pending and migrated v1 entries without an outcome block every different
  reservation. Dedicated readback may append confirmed resolution to the
  same node; the original mutation is never resent automatically.
- Per-execution Job-owned paths remain isolated. The authorization digest
  uses a stable typed-plan path template so repeated executions of the same
  reviewed plan do not acquire different authorization solely because their
  Job IDs differ.
- `capability inspect` exposes the durable envelope, remaining uses, blocker
  and complete lineage. E2 validation remains exactly one use.

## Verification

Commands executed from the repository root:

```text
swift test --package-path Packages/ArkDeckKit --filter RuntimeCapabilityStoreContractTests
swift test --package-path Packages/ArkDeckKit --filter RuntimeJobEngineContractTests
swift test --package-path Packages/ArkDeckKit --filter AgentDaemonContractTests
swift test --package-path Packages/ArkDeckKit --filter DiagnosticsAndHAPContractTests
CI=true swift test --package-path Packages/ArkDeckKit
```

Results:

- RuntimeCapabilityStore: pass, including hash-chain tamper detection, v1
  fail-closed migration, scope drift, pending and unknown outcome gates.
- RuntimeJobEngine: pass, including two distinct executions under one
  unchanged envelope and restart-preserved unknown-outcome blocking with
  zero redispatch.
- Agent daemon: pass, including multi-use draft and full lineage inspect.
- Diagnostics/HAP regression: 38 tests passed.
- Full ArkDeckKit suite: exit 0.

## Compatibility and residual boundary

- Existing v1 consumption rows contain no outcome fact. They remain
  `legacyUnverified` and blocked unless restart recovery finds the durable
  Job record with that exact reservation and appends its known/unknown
  outcome; migration alone never treats them as authorization.
- This delivery does not issue or approve a device capability, does not
  change acceptance count, and does not change GJ-1/GJ-2 real-device
  evidence. A future maintainer-approved E1 envelope may use the new bound
  without requiring one authorization PR per confirmed execution.
