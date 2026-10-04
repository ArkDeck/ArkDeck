# TASK-XPA-005 — GJ-1's oracles replayed on Windows host code

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. This layer is stacked on the Windows Job HDC
composition (`agent/xpa-005-windows-job-hdc-composition-20261004`), per the stacked-PR rule of
#2485.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## What

- **The fake's two GJ-1 tables.** `arkdeck-provider-hdc/tests/common/oracle_fake.rs` gains the
  `ObserveDevice` and `CaptureDiagnostics` arms. Each is picked by its fragment's first line and
  ports `observe-device/hdc-answers.sh` and `capture-diagnostics/hdc-answers.sh` case for case, by
  mode:
  - `emptyVersion`, `serverMismatch` and `otherDevice` for `observe.device@1`;
  - `otherDevice`, `lowStorage` and `emptyHilog` for `capture.diagnostics@1`.

  The two tables share the device rows and property reads (`fixture_device`). The existing arms
  are unchanged.
- **A read-only replay.** `hoststore/tests/support/hdc_oracle.rs`'s replay now takes the oracle's
  kind:
  - `assert_replays`: Jobs that mutate under one capability use each, every answer compared,
    message included. Unchanged.
  - `assert_read_only_replays` (new): Jobs admitted and run with no mutation owner, as both
    oracles ran them. No capability store is read or checked. A refusal's message is Swift's
    wording (T2), reported, not compared, as the macOS replays (`observe_device.rs`,
    `capture_diagnostics.rs`) do.
- **The Windows replays.** `hoststore/tests/windows_gj1_replays.rs` replays both oracles, 28
  exchanges each. The fake is pinned to no registered Windows tuple, so `probeHDCServer` keeps
  Swift's `checkserver` and the calls are Swift's. Checked:
  - every answer's code, details and result (no wording differed);
  - the fake's calls in order (11 and 16);
  - `targets.json`;
  - the Job index, records and Journals, every Artifact and the Sessions, byte for byte. Host
    paths are read in the oracle's spelling, the Session platform as the oracle's, and a
    manifest's length and digest relabelled one to one.

A mutation check, reverted before commit: changing the fake's HiLog line turns the
`capture.diagnostics@1` replay red at `captured.result`.

## Found for the next layer (not changed here)

Driving GJ-1's CLI leaves end to end through #2479's signed test daemon (a prototype, not
committed) found two gaps:

1. **The CLI's domain executor has no Windows home for a paused run.** Swift keeps a paused run's
   pending record "beside the Runtime's socket" (`domain_leaves::state_directory`). On Windows the
   endpoint is a named pipe, so that directory is `\\.\pipe\agent-runtime`, and creating it fails
   with `ERROR_PRIVILEGE_NOT_HELD` (1314). Every paused domain leaf (`target observe` without a
   proven relation, a reconnect, a target selection) fails with `persistence(...)` on Windows.
2. **The signed test daemon composes no USB relations.** A development root composes the
   Runtime's census only beside a registered tuple's managed HDC. So an observation of the fake's
   device is `generationScoped`, with no `adoptedTargetId`, and `target observe --target` pauses
   for a reconnect. Measuring the device leaves needs a USB-relation stand-in in the test build,
   beside `Host::with_test_hdc`.

Both are taken in the next layer, with the leaves' signed-CLI tests and the coverage.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.
