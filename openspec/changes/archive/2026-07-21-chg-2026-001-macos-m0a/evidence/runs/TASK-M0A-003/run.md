# TASK-M0A-003 run record — 2026-07-15

- Evidence class: `platform` (local macOS fake/contract suite; no hardware)
- Core baseline: `CORE-1.0.0`
- Integration profile: `OPENHARMONY-TOOLS@0.1.0`
- Scope: `MAC-M0A-HDC-002`; AC-HDC-002-01, AC-HDC-003-01/02,
  AC-HDC-010-01/02/03

## Environment

- macOS 26.5.1 (25F80), arm64
- Xcode 26.6 (17F113)
- Swift 6.3.3 (`swiftlang-6.3.3.1.3`, target `arm64-apple-macosx26.0`)

## Work completed

- Added the actor-isolated `HDCServerSupervisor` prototype as the host-wide
  owner of endpoint, health, version, ownership, and generation state. Devices
  and Jobs register against an endpoint and receive the same server event;
  other endpoints receive none.
- Existing-server observations can establish only `external` or `unknown`.
  `arkDeckManaged` requires an absent-endpoint authorization and verified PID,
  absolute tool path, endpoint, and generation evidence after launch.
- Automatic diagnostic paths have no lifecycle executor. They only broadcast a
  diagnostic, so `external` and `unknown` observations cannot reach stop,
  restart, `kill -r`, `start -r`, or subserver lifecycle code.
- Added typed lifecycle-step, impact-preview, confirmation, revalidation,
  critical-Job gate, audit-store, and affected-recipient broadcast models. The
  only executor used by tests is an in-memory recorder; no HDC executable or
  host lifecycle command was invoked.
- Added HDC server fixtures and twelve contract tests for shared event
  fan-out (generation change and health failure), automatic no-mutation
  behavior, managed-ownership evidence, critical-step blocking,
  preview/confirmation/audit correlation, stale-confirmation rejection,
  single-use confirmation, fail-closed impact uncertainty, the dedicated
  managed-start precondition, and post-intent revalidation of both the
  critical-job gate and the generation scope (see the review addendum).

## Commands and results

| Command | Result |
| --- | --- |
| `swift test --package-path Packages/ArkDeckKit` (after review fixes) | Passed: 36 XCTest cases, 1 explicitly skipped manual power-observation harness, 0 failures. The twelve `HDCServerSupervisorContractTests` exercise the stated HDC lifecycle cases using only fixtures and a recording fake executor. |
| `xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Debug -derivedDataPath /private/tmp/arkdeck-m0a-m003-derived clean build` | Passed: `** BUILD SUCCEEDED **`. |
| `scripts/check-sdd.sh` | Passed: `0 error(s), 0 warning(s), 110 acceptance IDs`. |
| `git diff --check` | Passed: no whitespace errors. |

## AC conclusion

- AC-HDC-002-01: **passed** in the supervisor fixture suite. A generation
  change is delivered as one host-wide server event to both device coordinators
  and the related Job; an isolated-endpoint recipient receives no event.
- AC-HDC-003-01: **passed** in the fixture suite. `external` and `unknown`
  automatic diagnostic failures have no lifecycle-executor path by
  construction; the test asserts the observable facts that they leave server
  state unchanged and append no lifecycle intent/outcome audit event.
- AC-HDC-003-02: **passed** in the fixture suite. A mismatched launch endpoint
  is rejected; only absent-endpoint authorization plus PID/tool/endpoint
  evidence yields `arkDeckManaged` ownership.
- AC-HDC-010-01: **passed** in the fixture suite. A post-confirmation critical
  flash state blocks dispatch (`0` recorder calls) and returns the Job, Step,
  and safe-boundary action.
- AC-HDC-010-02: **passed** in the fixture suite. The preview captures action,
  endpoint, generation, ownership, affected devices/Jobs, detected clients,
  interruption, and recovery path; confirmation, intent, outcome, and the
  broadcast share the typed step/audit correlation IDs.
- AC-HDC-010-03: **passed** in the fixture suite. Generation drift invalidates
  confirmation, creates a new preview, and leaves the executor call count at
  `0`.

`MAC-M0A-HDC-002` remains `pending` in the change-level verification matrix:
that row also includes endpoint-isolation and conservative-subserver evidence
outside this task's declared deliverables. This task's completion is not a
claim that the change is verified.

## Deviations and residual risk

- Evidence is local fake/contract evidence only; it does not prove a real HDC
  server, DevEco ownership, USB/UART/TCP connectivity, Flash, erase, unlock,
  update, or hardware support.
- No device was enumerated or targeted. No HDC command, host lifecycle command,
  or destructive operation was dispatched; destructive dispatch count is `0`.
- The supervisor's audit sink is deliberately injectable. Production durable
  journal integration and actual user-facing lifecycle dispatch remain later
  work; the prototype blocks dispatch if intent persistence fails.
- `MAC-M0A-HDC-001` (blocked in TASK-M0A-002) is **not** unblocked by this
  task alone: the supervisor is a prototype without a real lifecycle executor
  or probe wiring, so the safe installed-tool observation still cannot run.
  Re-observation belongs to the milestone that wires a real executor behind
  this gate.
- Task state is drafted as `done` on this agent branch because its declared
  deliverables and fixture verification are complete. The state only takes
  effect after maintainer review and merge; the Agent does not mark the change
  verified.

## Review addendum — 2026-07-15

Review of the initial implementation produced three fixes, re-verified in the
same environment:

- **Reentrancy gap (blocking, reproduced by a review probe):** `dispatch()`
  validated the critical-job gate and scope hash before appending the intent
  audit record, but `auditStore.append` is an actor suspension point, so a Job
  turning critical (or a generation change) during intent persistence still
  reached the executor. The dispatch path now re-validates the impact
  snapshot, scope hash, and critical-job gate synchronously after the intent
  append — the final non-suspending checks before the executor — and a
  post-intent block closes the audit trail with a
  `failed("blocked after intent persistence")` outcome and broadcast. Two
  regression tests drive the mutation from inside the audit append.
- **Tautological counter removed:** `automaticLifecycleMutationCount()`
  returned a hardcoded `0` and the automatic-path test asserted on it. The
  method is deleted; the test now asserts unchanged server state and an empty
  lifecycle intent/outcome audit trail instead.
- **Managed-start preview misuse** now fails with its dedicated precondition
  rather than a misleading `endpointStateUnknown` block.

The first fix iteration did not compile (`await` inside an XCTest autoclosure
at two assertion sites); this was corrected during final review verification,
after which the full suite passed (36 cases, 1 skipped, 0 failures) and the
review probe that previously demonstrated the gap passed.
