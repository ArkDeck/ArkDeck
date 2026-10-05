# TASK-XPA-005 — GJ-1's keyboard input end to end on Windows

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. Fourth layer of the stack, on the port
forwards layer (`agent/xpa-005-windows-gj1-port-forwards-20261005`). It measures `input keyboard`
(`input.keyboard@1`) and `artifact import keyboard-input` through the real signed CLI and the
signed test daemon.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## The reference

No Swift oracle records keyboard input: it was added in Rust and on macOS by #2473 (merged
2026-10-04). As the lead directed, it is measured against the macOS Rust answers. The reference is
the owner test `arkdeck-hoststore/tests/keyboard_input_run.rs`: its synthetic transport and the
end it expects for each reply.

## What

- **The fake's answers.** That transport is ported into the shared in-process fake
  (`Answers::KeyboardInput`), by mode:
  - The fixture's device rows and property reads.
  - One UiTest text action, `-t <key> shell uitest uiInput text <text>`, which is:
    - acknowledged (`No Error`);
    - echoed without its acknowledgement (`missingAck`);
    - unobserved (`unobservable`, `DispatchFailure::Unobservable`);
    - or refused (`refused`, `DispatchFailure::Refused`).
  - Any other call is refused as an unregistered action.
  - The last two replies carry the private text, as the macOS test's do.
  - The fake's `Answer` gains a dispatch refusal (`declined`) for the `refused` reply.
  - The test writes the answers' fragment and a tool file of its own beside the replay root, since
    there is no Swift fixture for it. Its Target is the oracles' adopted one.
- **The replay.** `keyboard_input_answers_as_the_macos_runtime_over_the_signed_test_daemon`
  (`gj1_inputs.rs`) runs each reply over a fresh root, with the board, a fixed clock and the
  replay's own Job state:
  - `artifact import keyboard-input` imports the private text as a `sensitive` Import. Neither the
    receipt nor the CLI's answer carries the text.
  - `input keyboard` with an intent older than ten seconds is refused, and nothing is sent.
  - With a current intent, each reply ends as in the macOS test, with the text action sent
    exactly once:
    - acknowledged: `succeeded`;
    - refused: `failed`;
    - unacknowledged or unobserved: an unknown outcome, with the Job `waitingForRecovery`. The
      next input is then refused (`admissionDenied`) and the first is never replayed.
  - No file under the daemon's Job state (Jobs, journal and capabilities) or its Sessions holds
    the private text.
- **Coverage.** `input.keyboard` and `artifact.import.keyboard-input` join
  `WINDOWS_MEASURED_LEAVES`, and `input.keyboard@1` is Windows `implemented`. The coverage was
  regenerated with `arkdeck maintainer contracts export`; `oracle.json` is not re-pinned.
  - Delegated minor decision, pending the next rulings batch: a leaf with no Swift oracle is
    counted when it is measured against the macOS Rust answers, as the lead directed for this
    slice.

No Windows defect was found.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.
