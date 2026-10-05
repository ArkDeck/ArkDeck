# TASK-XPA-005 — GJ-1's screen record end to end on Windows

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. Second layer of the stack, on the pointer
inputs layer (`agent/xpa-005-windows-gj1-inputs-20261005`). It measures `screen record`
(`capture.screen-sequence@1`) through the real signed CLI and the signed test daemon.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## What

- **The fake's answers.** The Swift screen-sequence oracle's fragment
  (`rust/tests/fixtures/screen-sequence/hdc-answers.sh`) is ported into the shared in-process fake
  (`Answers::ScreenSequence`): the device's free space (`lowStorage`), the frame directory
  (`residue` leaves a dot file in it), the stills (`gap` fails the second), the archive
  (`missingArchive`, `emptyArchive`), its readback and receive, and the cleanup, kept in the
  fake's `device-tmp`.
- **The replay.** `screen_record_answers_as_the_swift_oracle_over_the_signed_test_daemon`
  (`gj1_inputs.rs`) uses the first layer's replay. Every recorded case is sent in the oracle's
  order:
  - `captured`, `scaled`, `gap`: completed.
  - `lowStorage`, `emptyArchive`, `residue`: failed.
  - `missingArchive`: an unknown outcome, the Job `waitingForRecovery`.
  - `afterUnknown` (`admissionDenied`), `halfScaled` and `singleFrame` (`invalidInput`):
    refused, nothing sent.
  - Each Job's calls are exactly the oracle's, with its owned device paths named by this run's
    Job and a receive's host path compared by its file name. Each completed or failed run
    publishes as many Artifacts as the oracle's.
- **Capability names relabelled.** A non-session capability's name covers its plan digest. This
  operation's plan lowers the receive into the Runtime's receive root (`screen_sequence_plan.rs`),
  a host path spelled otherwise on Windows. So the capability names differ from Swift's, and only
  they. The replay maps each name to the oracle's one to one, learned from each run's evidence
  authority, as the GJ-2/3 replays relabel plan-derived values (rulings 48 and 61). The refusal
  after the unknown outcome and `capability list` then equal the oracle's. The pointer inputs'
  capabilities are session-scoped (no plan digest), so they map to themselves.
- **Coverage.** `screen.record` joins `WINDOWS_MEASURED_LEAVES`, and `capture.screen-sequence@1`
  is Windows `implemented`. The coverage was regenerated with `arkdeck maintainer contracts
  export`; `oracle.json` is not re-pinned.

No Windows defect was found.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.
