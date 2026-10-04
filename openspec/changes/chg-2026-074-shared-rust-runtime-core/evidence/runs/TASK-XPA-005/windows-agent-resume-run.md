# TASK-XPA-005 — `agent resume` end to end on Windows

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. This layer is stacked on the
`capture.diagnostics@1` legs layer (`agent/xpa-005-windows-capture-legs-20261004`). It measures
`agent.resume` end to end through the real signed CLI and the signed test daemon.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## What

- **The fake's human-action table** (`oracle_fake.rs`, `Answers::HumanAction`). It ports
  `agent-human-action/hdc-answers.sh`:
  - the device list `offline`, `unauthorized` or with `twoDevices`;
  - a Job held at its server check (`heldServer`) until `released` exists below the fake's root;
  - then `capture.diagnostics@1`'s table, which the fragment reuses.
- **`agent_resume_completes_a_paused_execution_over_the_signed_test_daemon`**
  (`agentd/tests/spawning/gj1_device_leaves.rs`). It follows the Swift human-action oracle's
  `connect` scenario through the real CLI.
  - There is no adopted Target and the device is offline. `agent run --operation observe.device@1
    --execution-id har-connect` pauses with exit 75 (`waitingForHuman`, `physicalConnection`,
    `device.notObserved`, `human.connectOrPowerDevice`). `human-action list` names its resume
    reference, and only the device list was read.
  - The daemon is restarted over the same root with the device connected and the board present.
    `agent resume --resume-reference` adopts the device (binding revision 1) and runs and completes
    the Job.
    - The Job is the oracle's own (`job-d166d1a72b51eb3b14528dae5cac37ee`).
    - Its three Artifacts' references, digests and sizes are the oracle's (`connect.completed`).
    - `agent status` reads `completed`, and the Job `succeeded`.
  - A second resume answers the same Job, and nothing is sent to the device again.
- **Coverage.** `agent.resume` joins `WINDOWS_MEASURED_LEAVES`, and the stale note that `agent run`
  and `agent resume` were not measured is corrected. The coverage was regenerated with
  `arkdeck maintainer contracts export`: `agent.resume` is Windows `implemented`. `oracle.json` is
  not re-pinned.

## Left out

- `agent abandon` and `human-action resume`. The lead asked for `agent.resume`.
- The oracle's other scenarios (trust, ambiguous, unproven) through the CLI. The owner-level
  Windows replay `hoststore/tests/windows_agent_human_action_resume.rs` covers them.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.
