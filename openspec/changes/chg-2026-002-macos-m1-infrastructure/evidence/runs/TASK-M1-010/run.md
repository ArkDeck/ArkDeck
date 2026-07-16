# TASK-M1-010 run record — 2026-07-16

- Evidence class: `contract` + `platform` (local macOS child-process, filesystem, and generated sparse-fixture tests)
- Core baseline: `CORE-2.0.0`
- Base revision: `55d4a415819e73e374cbb23755626d96de60390d`
- Branch: `agent/task-m1-010`
- Hardware / device / network: none
- Destructive or device dispatch count: `0`

## Environment

- macOS 26.5.2 (25F84), arm64
- Xcode 26.6 (17F113)
- Swift 6.3.3 (`swiftlang-6.3.3.1.3`, target `arm64-apple-macosx26.0`)

## Work completed

- Reclassified ProcessExecutor evidence output so only values directly observed by the
  executing test remain; removed uninstrumented child-launch, host-shell, and
  forced-kill-count echoes. The TASK-M1-002 historical record is retained verbatim
  before its evidence-integrity addendum.
- Removed zero-count decorations whose preceding assertions already prove rejection,
  state, directive, or invariant-violation behavior in `JobStateMachineTests` and
  `WorkflowStepContractTests`.
- Renamed the public source API case
  `ProcessSemanticResult.indeterminate` to `ProcessSemanticResult.unknownOutput`.
  This is an intentional source-breaking API rename for callers of that public enum;
  the case's third-state behavior is unchanged. It now aligns with existing
  `HDCCommandSemanticResult.unknownOutput` and the journal `outcomeUnknown` family.
- Left `HDCSemanticOutputParser` behavior and executor wiring unchanged. Its sole
  new comment records that TASK-M1-006 will adopt `ProcessSemanticEvaluating`.
- Removed six M0A `testProcessExecutor*` prototypes now duplicated by the dedicated
  ProcessExecutor suite and added canonical `TEST-AC-*` anchors to that suite's test
  names.

## Evidence-output classification and final observations

The following values are from the final full-suite run, not source literals:

| Observation | Value | Source |
| --- | ---: | --- |
| direct-probe payload argv elements | 3 | captured stdout split by the test separator |
| shell-expansion sentinel files | 0 | filesystem lookup |
| recorded fixture PIDs per process-tree case | 2 | fixture stdout parsed at runtime |
| surviving recorded processes per process-tree case | 0 | `kill(pid, 0)` probe |
| forced kill observed per controlled termination | 1 | executor `ProcessGroupTerminationResult` Boolean |
| leader-exit cancellation elapsed duration | 0.322263956 s | `Date` interval |
| leader-exit timeout elapsed duration | 0.500758052 s | `Date` interval |
| sparse fixture logical size | 1,073,741,824 bytes | `lstat` |
| sparse fixture allocated size | 0 bytes | `lstat` |
| stdout bytes streamed | 1,073,741,824 | executor result / callback counter |
| stdout callback dispatches | 50,282 | callback counter |
| retained stdout / stderr | 65,536 / 0 bytes | executor capture |
| sampled peak RSS delta | 163,840 bytes | Mach task sampling |

No direct instrumentation exists for total child launches, host-shell spawns, or
signal invocation count. TASK-M1-010 deletes those former echoes rather than relabeling
them as measurements. `forced_kill_observed` is specifically a Boolean outcome from
the executor, not a count of `SIGKILL` calls.

## Test-count reconciliation

`git grep` at the base revision found 108 XCTest `func test...` declarations under
`Packages/ArkDeckKit/Tests`; the current working tree found 102. The six-test delta is
exactly the removed M0A `testProcessExecutor*` prototypes. The dedicated
`ProcessExecutorContractTests` suite remains 10 tests.

## Commands and results

| Command | Result |
| --- | --- |
| `swift format lint <all six changed Swift files>` | Passed, exit 0. It emitted non-fatal legacy indentation/line-length warnings in pre-existing file style; no formatter rewrite was applied. |
| `swift test --package-path Packages/ArkDeckKit --filter ProcessExecutorContractTests` | Passed: 10 tests, 0 failures, 0 skipped. |
| `swift test --package-path Packages/ArkDeckKit` | Passed: 102 tests, 0 failures; 1 unrelated manual power-observation harness skipped because `ARKDECK_POWER_OBSERVATION` was not set. |
| `scripts/check-sdd.sh` | Passed: 0 errors, 0 warnings, 111 acceptance IDs. |
| `git diff --check` | Passed. |
| static check for `.indeterminate`, `testProcessExecutor*`, and listed decorative counters | Passed for TASK-M1-010's target files; unrelated journal counters remain outside this task's scope. |

## Requirement → AC → regression conclusion

| Requirement | Acceptance | Regression evidence | Conclusion |
| --- | --- | --- | --- |
| `REQ-WF-001` | `AC-WF-001-01` | `WorkflowStepContractTests` rejects unregistered host commands and unsafe shell surfaces before dispatch | **passed** (`contract`) |
| `REQ-JOB-001` | `AC-JOB-001-01`, `AC-JOB-001-05` | `JobStateMachineTests` verifies planned state and all recovery-resume preconditions/directives | **passed** (`contract`) |
| `REQ-JOB-003` | `AC-JOB-003-01` | `JobStateMachineTests` verifies the critical cancellation directive prohibits forced termination | **passed** (`contract`) |
| `REQ-JOB-005` | `AC-JOB-005-01` | canonical ProcessExecutor tests verify argv/no-shell, semantic exit-zero failure, stream separation, preflight, timeout, cancellation, and process trees | **passed** (`contract`) |
| `REQ-NFR-002` | `AC-NFR-002-01` | canonical 1 GiB sparse-fixture test verifies streaming, bounded retention, and sampled RSS bound | **passed** (`platform`) |
| `REQ-HDC-005` | `AC-HDC-005-01` | existing `ProcessAndHDCContractTests` failure-marker parser cases pass; parser behavior was not changed | **passed** (`contract`) |

## Deviations and residual risk

- No task-scope deviation. No Core Requirement, AC, contract, baseline, platform or
  integration profile, conformance status, release claim, ProcessExecutor behavior,
  Job-state behavior, WorkflowStep decoder behavior, or HDC parser behavior changed.
- `ProcessSemanticResult.unknownOutput` is a public API rename. Downstream callers of
  `.indeterminate` must migrate at compile time; no compatibility alias is introduced
  because the task explicitly requires the vocabulary rename.
- The local suite cannot prove the behavior of external package consumers or M1-006's
  future evaluator/parser wiring. Those remain outside this task. Evidence remains
  local contract/platform evidence and never claims real hardware support.

## Task conclusion

All TASK-M1-010 deliverables and its evidence gate are satisfied. The drafted `done`
state becomes authoritative only after maintainer review and merge; this record does
not mark the change verified or alter macOS conformance/release status.
