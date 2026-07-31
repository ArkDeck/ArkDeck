# GJ-4 operation availability CLI — 2026-07-31

- Base: `main@67c177d78f1f29633a936797aec0e1b785e46c78`
- Delivery: existing `TASK-DHA-001` product follow-up; no new change, task,
  readiness, Acceptance ID, evidence schema or governance state.
- Duplicate check: merged PR #848 implements the GJ-5 evaluator and is
  unrelated to this GJ-4 availability surface. Historical `TASK-BRC-004` was
  not reactivated.

## Product result

The daemon already exposed authoritative runtime availability through
`operation.list`, but the product CLI had no corresponding command. An
engineer or Agent therefore had to construct a raw Unix-domain-socket frame to
learn whether a production operation could materialize.

This delivery adds:

```text
arkdeck operation list [--socket <path>] [--json]
```

The command is a thin `AgentClient` call to the existing daemon method. It has
no HDC, RockUSB, executable, argv, target, capability or dispatch surface.
Unknown arguments fail with `EX_USAGE`.

The real daemon process contract now launches the real `arkdeck` executable,
queries the user-private socket, parses its JSON result and confirms that the
CLI exposes the same `flash.dayu200@1` availability as the daemon.

## Signed-product host run

The exact reviewed unsigned component from workflow artifact `8640763234` was
revalidated at SHA-256
`3caee2136551b4b849daf7e9a906813354f354f8adb61e5f092de49ec7a2e56a`.
The existing release archive recipe then produced a local Developer ID signed
ArkDeck archive. Independent checks confirmed the nested component:

- designated identifier `com.arkdeck.desktop.rkdeveloptool`;
- Team ID `8AQTYW5FKR`;
- Hardened Runtime and secure timestamp;
- strict all-architecture signature validity;
- signed-file SHA-256
  `974094fec1ed306c8d6b87a70694fee089ac36e404c5245a0cf34ce1a1792d17`.

The signed component and the real `arkdeck-agentd`/`arkdeck` binaries were
placed in an isolated canonical product-sibling layout. The daemon was started
with an explicit HDC executable fact and an empty state directory. Running:

```text
arkdeck operation list --socket <isolated-agentd.sock> --json
```

returned:

```text
flash.dayu200@1 availability=available reasons=[]
```

An initial launch through the non-canonical `/private/tmp` alias correctly
returned `non-canonical or symlinked`; relaunching the same bytes through
canonical `/tmp` returned `available`. The strict resolver was not weakened.

This archive was not notarized, stapled, installed or published. It proves the
production component identity and availability path, not the complete release
package or a hardware Flash result.

## Verification

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter AgentDaemonContractTests.testDaemonBinaryStaysAliveAndServesRequests
```

Result: 1 process-level test, 0 failures.

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter 'AgentDaemonContractTests|RockchipRuntimeCompositionContractTests|HarnessEvaluationContractTests'
```

Result: 47 tests, 0 failures. This includes the GJ-5 evaluator merged in #848
and proves the new CLI surface composes cleanly with the latest `main`.

```text
CI=true swift test --package-path Packages/ArkDeckKit
```

Result: 797 tests, 0 failures; 1 existing manual sleep/wake test skipped.

## Device/effect boundary

- DAYU200 real-device execution: not performed.
- Job submission, HDC process execution, RockUSB process execution, USB access,
  capability creation/consumption, device mutation and destructive dispatch:
  all `0`.
- The explicit HDC path was hashed as a production executable fact only; no HDC
  command was invoked.
- Real destructive Flash remains human-operated under `REQ-FLASH-015`.
- GJ-4 remains `BLOCKED_BY_PRODUCT_DEFECT`: the product availability path now
  has a normal CLI and passes against signed bytes, but the reproducible
  notarized/stapled package is still unavailable because the prior DMG was
  never published and no current notary credential profile exists.
