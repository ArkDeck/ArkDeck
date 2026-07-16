# TASK-M1-002 run record — 2026-07-16

- Evidence class: `contract` + `platform` (local macOS child-process and generated-fixture tests)
- Core baseline: `CORE-2.0.0`
- Core conformance: `CORE-CONFORMANCE-2.0.0`
- Integration profile: `OPENHARMONY-TOOLS@0.1.0`
- Base revision: `bf8754390cca1cb4b4beaeb67ece762819f7b0a9`
- Branch: `agent/task-m1-002`
- Hardware / device / network: none
- Destructive or device dispatch count: `0`

## Environment

- macOS 26.5.2 (25F84), arm64
- Xcode 26.6 (17F113)
- Swift 6.3.3 (`swiftlang-6.3.3.1.3`, target `arm64-apple-macosx26.0`)

## Locked inputs

| Input | SHA-256 |
| --- | --- |
| `openspec/baselines/CORE-2.0.0.yaml` | `07227da529608f26dcbbc8843f1623278b51cb3036cd93e1e9ed4af6f8880aa6` |
| `openspec/verification/core-conformance.yaml` | `293cc22936c1079d434c52e23572b6f575c71715d98d32018cde4ecf0deba839` |
| `openspec/specs/workflow-journal-recovery/spec.md` | `0d94128bd06292b1d9ae24a29353a1cbf5591b6c96cd560a139c37d42c357d25` |
| `openspec/architecture/platform-ports.md` | `47752d0cc767867762ef1bc2f65d4aafbd20e81a5622e43320509ffac27a9962` |
| `openspec/platforms/macos/profile.md` | `54bd9b295799cb8d93bf397eeb585f24828463f4f1fce1e59a0693f65369d0bf` |
| `openspec/verification/acceptance-cases.yaml` | `a8b4e9c0e9fd0bdeb369db18261a8be31324151a68fa710a30e29183b50a476d` |
| `openspec/integrations/INTEGRATION-PROFILES.lock.yaml` | `ea4e89905abc02717049a651356ecfe6148ea85e820a7d442aa06686c1a52f04` |
| `openspec/platforms/PLATFORM-PROFILES.lock.yaml` | `6ed7ae92343f93693555fef4e5831cd363f6d0c5dcb7fbdd4d651d6d506a1212` |
| `openspec/changes/chg-2026-002-macos-m1-infrastructure/tasks.md` | `6d03b8092686eb95467e4026736b4e798f2f3b8606c9966230072b4b5a8ee9cc` |
| `openspec/changes/chg-2026-002-macos-m1-infrastructure/scope.yaml` | `2b6157ff202cda41f601445cee986c7fadb8d60a6b2ef2a924f13051a12b6265` |

The `tasks.md` hash above is the ready task packet at the base revision, before this
implementation PR drafts its `done` status.

## Work completed

- Replaced the prototype pipe readers with fixed-window POSIX byte drains and retained
  independent stdout/stderr capture capped at 64 KiB per stream by default.
- Added explicit `exit`, `signal`, `timeout`, and `cancel` termination classifications.
  Timeout/cancel sends `SIGTERM` to the dedicated process group, escalates to `SIGKILL`
  after a bounded grace period, and reports confirmed or unconfirmed group cleanup
  separately from the leader's result.
- Kept timeout/cancel active through pipe drain even after the process-group leader has
  exited. Pipe readers use a 25 ms `poll` interval and close their read descriptors when
  control is stopped, so drain has an explicit bounded cancellation path rather than
  depending only on descendant pipe EOF.
- Added a streaming Adapter semantic-evaluator contract. It consumes every raw chunk
  before capture truncation and returns a semantic result independently from exit code.
- Tightened spawn preflight for relative/non-file executables, NUL executable/argv/env,
  invalid environment keys, and zero/negative/non-finite timeout values.
- Added deterministic argv/no-shell, byte-stream, invalid UTF-8, exit-zero semantic
  failure, signal, timeout/cancel process-tree, leader-exit/descendant-pipe, and 1 GiB
  sparse-fixture contract tests.

## P1 review reproduction and remediation

The review report was reproduced before the fix with
`swift test --package-path Packages/ArkDeckKit --filter LeaderExitWhileDescendantHoldsPipes`:

| Pre-fix case | Observed |
| --- | --- |
| leader exits immediately; child holds pipes for 3 s; request timeout 0.2 s | Failed after 3.006 s with `exited(0)` / `notRequested` instead of `timedOut`. |
| leader exits immediately; child holds pipes for 3 s; caller cancels after 0.3 s | Failed 2.705 s after cancellation with `exited(0)` / `notRequested` instead of `cancelled`. |

Root cause: `waitpid` called `markFinished` before pipe drain, and `ProcessControl.stop`
discarded timeout/cancel after that marker. The correction removes the leader-exit gate,
keeps the control alive until drain and process-group cleanup complete, and makes each
pipe reader observe cancellation through bounded `poll` waits. The same two regression
cases pass after the correction with the metrics below.

## Commands and results

| Command | Result |
| --- | --- |
| `swift format lint Packages/ArkDeckKit/Sources/ArkDeckProcess/ArkDeckProcess.swift Packages/ArkDeckKit/Tests/ArkDeckContractTests/ProcessExecutorContractTests.swift Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ProcessExecutor/ProcessExecutorFixtures.swift` | Passed, exit 0, no diagnostics. |
| `swift test --package-path Packages/ArkDeckKit --filter LeaderExitWhileDescendantHoldsPipes` (before fix) | Expected reproduction failure: 2 tests, 6 assertions failed; confirmed `exited(0)` / `notRequested` and approximately 3 s pipe-EOF delay. |
| `swift test --package-path Packages/ArkDeckKit --filter ProcessExecutorContractTests` | Passed after fix: 10 tests, 0 failures, 0 skipped. |
| `swift test --package-path Packages/ArkDeckKit` | Passed after fix: 83 tests, 0 failures; 1 unrelated pre-existing manual power-observation harness skipped because `ARKDECK_POWER_OBSERVATION` was not set. |
| `scripts/check-sdd.sh` | Passed: 0 errors, 0 warnings, 111 acceptance IDs. |
| `git diff --check` | Passed. |

## Contract counters and resource metrics

Canonical metrics below are from the final filtered
`ProcessExecutorContractTests` run at 2026-07-16 10:32 local time.

| Metric | Observed |
| --- | ---: |
| argv elements delivered to direct probe | 4 |
| direct child launches for argv probe | 1 |
| host-shell spawns | 0 |
| shell-expansion sentinel files | 0 |
| invalid preflight cases | 9 |
| child launches across invalid preflight cases | 0 |
| timeout fixture recorded process-group members | 2 |
| timeout surviving recorded members | 0 |
| timeout forced-kill count | 1 |
| cancellation fixture recorded process-group members | 2 |
| cancellation surviving recorded members | 0 |
| cancellation forced-kill count | 1 |
| leader-exit timeout recorded process-group members | 2 |
| leader-exit timeout surviving recorded members | 0 |
| leader-exit timeout forced-kill count | 1 |
| leader-exit timeout elapsed duration | 0.519161 s |
| leader-exit cancellation recorded process-group members | 2 |
| leader-exit cancellation surviving recorded members | 0 |
| leader-exit cancellation forced-kill count | 1 |
| leader-exit elapsed duration after cancellation | 0.313267 s |
| sparse fixture logical size | 1,073,741,824 bytes |
| sparse fixture allocated size | 0 bytes |
| stdout bytes consumed by streaming callback | 1,073,741,824 |
| stdout callback dispatches | 31,952 |
| retained stdout capture | 65,536 bytes |
| retained stderr capture | 0 bytes |
| sampled peak RSS delta | 327,680 bytes |
| allowed peak RSS delta | 67,108,864 bytes |
| RSS sampling failures | 0 |

The sparse fixture was created with a 1 GiB logical length and read by `/bin/cat` as
one real child process. RSS was sampled from `MACH_TASK_BASIC_INFO.resident_size` every
128 stdout dispatches and once after completion; it was not inferred from the lifetime
high-water mark.

## Requirement → AC → test → evidence

| Requirement / Port | Acceptance / gate | Test evidence | Conclusion |
| --- | --- | --- | --- |
| `REQ-JOB-005` | `AC-JOB-005-01` / `TEST-AC-JOB-005-01` | `ProcessExecutorContractTests`: special executable path and argv round-trip; expansion sentinel; separated streams; invalid UTF-8; exit-zero semantic failure; signal/timeout/cancel/process-tree cases, including leader exit before descendant pipe EOF | **passed** (`contract`) |
| `REQ-NFR-002` | `AC-NFR-002-01` / `TEST-AC-NFR-002-01` | 1 GiB sparse generated fixture; exact callback byte count; 64 KiB retained capture; sampled 327,680-byte peak RSS delta | **passed** (`platform`) |
| `PORT-PROCESS-001` | absolute executable, argument array, independent byte streams, timeout/cancel, no shell, invalid preflight | Dedicated 10-case suite plus zero-launch, bounded-drain, and zero-survivor counters | **passed** (`platform`) |

## Deviations and residual risk

- No task-scope deviation. No Core Requirement, AC, contract, baseline, platform
  conformance, or release claim changed.
- Process-group termination controls members that remain in the dedicated POSIX group.
  A hostile child that deliberately creates a new session/process group is outside this
  confirmation boundary; Adapters must not invoke daemonizing tools as ordinary managed
  commands. An inability to confirm group disappearance is represented as
  `unconfirmed`, never as successful cleanup.
- Evidence is local macOS contract/platform evidence only. It is not real hardware,
  HDC server ownership, device, network, Flash, erase, unlock, update, or release
  evidence.
- The skipped manual power-observation harness belongs to a different runtime Port and
  does not affect either TASK-M1-002 AC or `PORT-PROCESS-001`.

## Task conclusion

All TASK-M1-002 deliverables and its evidence gate are satisfied. The drafted `done`
state becomes authoritative only after maintainer review and merge; this record does
not mark the change verified or alter macOS conformance/release status.
