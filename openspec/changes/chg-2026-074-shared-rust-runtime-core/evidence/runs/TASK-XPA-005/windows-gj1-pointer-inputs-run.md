# TASK-XPA-005 — GJ-1's pointer inputs end to end on Windows

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. First layer of a stack (pointer inputs,
then screen record, port forwards and keyboard input), based on `main`. It measures `input tap`,
`input long-press` and `input swipe` (`input.tap@1`, `input.long-press@1`, `input.swipe@1`)
through the real signed CLI and the signed test daemon.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## What

- **The fake's answers.** The Swift pointer-input oracle's fragment
  (`rust/tests/fixtures/pointer-input/hdc-answers.sh`) is ported into the shared in-process fake
  (`arkdeck-provider-hdc/tests/common/oracle_fake.rs`, `Answers::PointerInput`), case for case:
  the fixture's device rows and property reads, `uinput`'s click, touch down/up and move echoes
  with its boundary hint, and the `rejected`, `silent` and `otherGesture` modes.
- **The replay.** `pointer_inputs_answer_as_the_swift_oracle_over_the_signed_test_daemon`
  (`arkdeck-agentd/tests/spawning/gj1_inputs.rs`) starts the signed test daemon with the board,
  the oracle's fixed clock (the inputs carry a screen epoch with a 1000 ms freshness bound) and
  its own Job state for the mutations' continuity. It sends every case the oracle recorded, in
  the oracle's order, through the leaf of the case's operation, with the fake in the case's mode:
  - `tap`, `longPress`, `swipe`: completed (exit 0), the oracle's step kinds, the Job
    `succeeded`.
  - `rejected`: the run's receipt and exit 1, the Job `failed`.
  - `otherGesture`: the receipt says `outcomeUnknown`, exit 1, and the Job is
    `waitingForRecovery`, as the oracle's was.
  - `expired`, `outOfFrame`, `shortHold`, `swipeWithoutDuration` (`invalidInput`) and
    `afterUnknown` (`admissionDenied`, the lineage blocked by the unknown use): refused with the
    oracle's code and words, nothing sent.
  - For each Job, the calls the fake received, the device list reads aside (the CLI's own
    observation adds some), are exactly the oracle's calls of that Job.
  - `capability list` afterwards equals the oracle's `capabilities.list` answer: the three
    standing capabilities, their use counts, and the tap capability's lineage blocked at use 3.
- **Coverage.** `input.tap`, `input.long-press` and `input.swipe` join `WINDOWS_MEASURED_LEAVES`;
  the three operations are Windows `implemented`. The coverage was regenerated with
  `arkdeck maintainer contracts export`; `oracle.json` is not re-pinned.
- `gj1_device_leaves.rs` shares its fixture constants and helpers (`roots`, `calls`,
  `assert_windows_status`) with the new module; nothing else there changed.

No Windows defect was found: every answer matched on the first run once the test read the Job's
state from `job status` (the receipt's `terminalState` is the evidence's, `outcomeUnknown`, on
both hosts).

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.
