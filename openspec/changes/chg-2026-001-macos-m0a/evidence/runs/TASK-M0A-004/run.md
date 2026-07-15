# TASK-M0A-004 run — 2026-07-15

## Scope and environment

- Change: `CHG-2026-001-macos-m0a`; baseline: `CORE-1.0.0`.
- Branch: `agent/task-m0a-004-runtime-journal-power`.
- Host classification: local macOS package/host-process test only; no HDC command, server operation, device access, or hardware workflow was run.
- Toolchain: Apple Swift 6.3.3 (`swift-driver` 1.148.6), target `arm64-apple-macosx26.0`.

## Commands and results

```text
swift test --scratch-path /private/tmp/arkdeck-m0a-m004-build
```

Result: after rebasing onto `origin/main`, 24 package tests executed; 23 passed, 1 deliberately skipped manual-observation harness, 0 failures. The runtime/storage contract suite covers:

- A primary `SingleInstanceGuard` atomically acquiring `O_EXLOCK | O_NONBLOCK` while a real second host process attempts non-blocking BSD `flock`; the second process cannot take the lock. Its fixture performs only that lock attempt, with no HDC or Session operation.
- Lock release followed by a replacement guard acquisition; lock-file symlink following is refused (`O_NOFOLLOW`).
- A failed journal append/full-sync fault injection returning `intentNotDurable`; the external-operation closure count remains 0. A production journal write now requires both `FileHandle.synchronize()` and `fcntl(F_FULLFSYNC)`; failure of either blocks dispatch.
- Contract-shaped `journal-event-1.0.0` `stepIntent` encoding, append-only JSONL recovery of an incomplete intent/torn tail, and durable outcome before atomic checkpoint publication.
- Reference-counted power leases releasing on explicit end, deinitialization, success, throw/failure, and task cancellation. The production backend uses `ProcessInfo.beginActivity(.idleSystemSleepDisabled)` and explicitly states that it does not cover lid closure or explicit user sleep.

```text
scripts/check-sdd.sh
```

Result: `check_sdd: 0 error(s), 0 warning(s), 110 acceptance IDs`.

## AC conclusions

| AC / port | Conclusion | Evidence classification |
| --- | --- | --- |
| `AC-JOB-008-01` / `MAC-M0A-RUNTIME-001` | passed: one kernel-backed writer; the verified losing-process fixture has no HDC or Session path. | local two-process contract test |
| `AC-JOB-002-01` / `MAC-M0A-JOURNAL-001` | passed: unsuccessful durable intent prevents the external operation; incomplete records require recovery; outcome precedes checkpoint. | local fault-injection/contract test |
| `PORT-POWER-001` / `MAC-M0A-POWER-001` | passed: automated ref-count and terminal-path tests pass, and the manual idle-sleep observation (record below) confirmed the production assertion is created under the declared reason and released on lease end. | local unit test + maintainer-observed host assertion |

## Manual idle-sleep observation runbook

The following is a human-executed host observation, not a hardware workflow. Use two terminals on the macOS host.

1. In terminal A, start the explicit, bounded harness (default 60 seconds; choose 15–300 seconds):

   ```text
   cd /Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/Packages/ArkDeckKit
   ARKDECK_POWER_OBSERVATION=1 ARKDECK_POWER_OBSERVATION_SECONDS=60 swift test --scratch-path /private/tmp/arkdeck-m0a-m004-build --filter RuntimeAndStorageContractTests.testManualIdleSleepObservationHarness
   ```

2. While that test is sleeping, in terminal B capture:

   ```text
   pmset -g assertions | rg 'ArkDeck M0A manual power observation|PreventUserIdleSystemSleep'
   ```

   Record the line containing the exact `ArkDeck M0A manual power observation` reason and its `PreventUserIdleSystemSleep` assertion.

3. After terminal A exits, repeat the terminal-B command. The entry bearing that exact ArkDeck reason must be absent. Other processes may independently hold idle-sleep assertions and must not be attributed to ArkDeck.

4. Append the command output, human operator, time, macOS build and pass/fail result to this run record; only then may `MAC-M0A-POWER-001` be reconsidered.

## Manual idle-sleep observation record — 2026-07-15

- Operator: the repository maintainer observed and captured both `pmset`
  outputs in a separate terminal. The harness itself was started by the Agent
  at the maintainer's direction (`ARKDECK_POWER_OBSERVATION=1`,
  `ARKDECK_POWER_OBSERVATION_SECONDS=180`); the Agent verified the harness
  process identity and clean exit but performed no `pmset` observation.
- Host: macOS 26.5.1 (25F80), arm64.
- During the harness window, `pmset -g assertions` (filtered per the runbook)
  showed, alongside unrelated `powerd`/`sharingd` assertions:

  ```text
  pid 71213(xctest): [0x001b9ecf00019fc2] 00:00:51 PreventUserIdleSystemSleep named: "ArkDeck M0A manual power observation"
  ```

  `pid 71213` matched the running harness
  (`xctest … testManualIdleSleepObservationHarness`), which later exited
  cleanly (`Executed 1 test, with 0 failures … in 180.107s`).
- After the harness exited, the same command showed no assertion bearing the
  ArkDeck reason; only the unrelated `powerd` ("Prevent sleep while display is
  on") and `sharingd` ("Handoff") entries remained, and they are not
  attributed to ArkDeck.
- Result: **pass**. The production `ProcessInfo` lease creates exactly one
  `PreventUserIdleSystemSleep` assertion under the declared reason and
  releases it when the lease ends. Per `PORT-POWER-001`, this covers idle
  sleep only; no claim is made about lid closure or explicit user sleep.

## Residual risk and handoff

The idle-sleep observation is recorded above, so M004 is drafted as `done`
(effective on maintainer merge). This run is not hardware evidence and does
not establish HDC/device support.

The journal prototype intentionally does not yet enforce monotonic sequences, recovery reads the complete journal into memory, and `WriteAheadIntentGate` presents the normalized `intentNotDurable` error rather than its underlying I/O detail. `Foundation.Process` is used only by the two-process test fixture, not by product source.
