# TASK-XPA-005 — GJ-1's device leaves end to end on Windows

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. This layer depends on the CLI's
paused-run state on Windows (`agent/xpa-005-windows-cli-executor-state-20261004`). It drives
GJ-1's CLI leaves through #2479's signed test daemon, over #2499's Job composition and #2503's
fake tables.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## What

- **A board for the signed test daemon** (`tests/spawning/signed_daemon.rs`, test only).
  - `SignedDaemon::start_with_board` passes the child a serial.
  - The child's Host then reads a synthetic USB census: one HDC-normal DAYU200 (`0x2207:0x5000`,
    one attachment) whose serial is the fixture's connect key. It is read through the production
    census relations (`Host::with_usb_registry_relations`), as a registered HDC's composition reads
    the Runtime's own census.
  - An observation of the fake's device is then `relationProven` and tied to the adopted Target.
    Without it, it stays `generationScoped`, and the CLI pauses for a reconnect.
  - `SignedDaemon::start` (CI2's) is unchanged; `pipe()` names the pipe it serves.
- **`tests/spawning/gj1_device_leaves.rs`**: the real signed `arkdeck.exe` against that daemon,
  over the Target the Swift oracles adopted. Each test compares the fake's calls after the CLI's
  observation reads (`list targets -v`) with the oracle's first Job's calls
  (`hdc-invocations.log`).
  - `target observe` (`observe.device@1`):
    - Without the board, it pauses for a reconnect with exit 75. The pending record is kept
      owner-only below the account's local application data (the CLI-state fix), and nothing is
      run.
    - The daemon is restarted over the same root with the board. `agent resume --resume-token`
      completes the run: one resolved pause, the evidence observed on the oracle's device
      (model, firmware), 3 Artifacts read back, and the record removed.
    - Run directly, it completes with no pause, and the Job's calls are the oracle's 5 (`-v`,
      `checkserver`, `list targets -v`, the two property reads).
  - `diagnostics capture --inputs-file` (`capture.diagnostics@1`, the oracle's `durationSeconds:
    5`): it completes with 6 Artifacts read back, and the Job's calls are the oracle's 6.
- **Coverage.** `WINDOWS_MEASURED_LEAVES` gains `target.observe` and `diagnostics.capture`. The
  coverage was regenerated with `arkdeck maintainer contracts export`, not hand-edited:
  - `observe.device@1` turns Windows `implemented`;
  - `capture.diagnostics@1` stays `partial` until its other five leaves are measured.

  `rust/tests/fixtures/maintainer-contracts/oracle.json` is not re-pinned: since #2465 it is a
  historical recording whose pins the replay never checks (the lead's decision of 2026-10-04).

## Left out

- **The other capture presets** (`trace capture`, `screen capture`, `ui-dump capture`,
  `ui-dump component-detail`, `debug logs`). They need the file and trace legs' fake tables
  (`capture-diagnostics-file-legs`, `-trace`, `-read-legs`) and a receive root, which are not
  ported yet.
- **`agent resume` as a measured leaf.** Its coverage entry is the daemon's `agent.resume` (an
  agent execution's resume over a Target). Only the client-side `--resume-token` path is measured
  here.
- **The commandless `probeHDCServer` lowering** is #2509. The fake is pinned to no registered
  tuple, so these runs keep Swift's `checkserver`, as the oracle recorded.
- **Delegated minor decision, pending the next rulings batch.** The test daemon's synthetic census
  goes through the production relations, as a test stand-in in the test build only. There is no
  new Host seam.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.
