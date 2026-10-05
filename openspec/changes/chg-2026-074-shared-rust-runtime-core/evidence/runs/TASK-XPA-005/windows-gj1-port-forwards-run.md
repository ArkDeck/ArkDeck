# TASK-XPA-005 — GJ-1's port forwards end to end on Windows

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. Third layer of the stack, on the screen
record layer (`agent/xpa-005-windows-gj1-screen-record-20261005`). It measures `port-forward
create` and `port-forward remove` (`port-forward.create@1`, `port-forward.remove@1`) through the
real signed CLI and the signed test daemon.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## What

- **The fake's answers.** The Swift port-forward oracle's fragment
  (`rust/tests/fixtures/port-forward/hdc-answers.sh`) is ported into the shared in-process fake
  (`Answers::PortForward`): forward (`fport tcp:`) and reverse (`rport tcp:`) rules kept as marker
  files below the fake's root, their listing (`fport ls`), and their removal (`fport rm`), with
  the `createRefused`, `readbackUnanswered` and `ruleUnlisted` modes.
- **The replay.** `port_forwards_answer_as_the_swift_oracle_over_the_signed_test_daemon`
  (`gj1_inputs.rs`) uses the first layer's replay. Every recorded case is sent in the oracle's
  order:
  - `createForward`, `removeForward`, `createReverse`, `removeReverse`: completed.
  - `createRefused`, `removeMissing`, `ruleUnlisted`: failed.
  - `readbackUnanswered`: an unknown outcome, the Job `waitingForRecovery`.
  - `afterUnknown` (`admissionDenied`), `privilegedPort`, `unknownDirection` and
    `withoutDevicePort` (`invalidInput`): refused, nothing sent.
  - Each Job's calls are exactly the oracle's: for `ruleUnlisted`, the create, the readback, the
    compensating removal and its readback. Afterwards the fake device keeps only the rule whose
    readback went unanswered.
  - `capability list` equals the oracle's, with the second layer's one-to-one relabelling of
    capability names.
- **Coverage.** `port-forward.create` and `port-forward.remove` join `WINDOWS_MEASURED_LEAVES`,
  and both operations are Windows `implemented`. The coverage was regenerated with `arkdeck
  maintainer contracts export`; `oracle.json` is not re-pinned.

No Windows defect was found.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.
