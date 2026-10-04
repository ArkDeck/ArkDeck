# TASK-XPA-005 — GJ-1's human-action loop end to end on Windows

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. This layer is stacked on the `agent.resume`
layer (`agent/xpa-005-windows-agent-resume-20261005`). It measures `agent abandon` and
`human-action resume` through the real signed CLI and the signed test daemon. `human-action list`
and `show` were already measured.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## What

`the_human_action_loop_runs_over_the_signed_test_daemon` (`agentd/tests/spawning/gj1_device_leaves.rs`)
follows the Swift human-action oracle's `trust` and `connect` scenarios (`agent-human-action`):

- **`connect`, paused.** With no board and the device offline,
  `agent run --operation observe.device@1 --execution-id har-connect` pauses for the device to be
  connected.
- **`trust`.** The daemon is restarted with the board and the device asking for trust.
  - `agent run … har-trust` pauses on `deviceTrustPrompt`.
  - `agent abandon` under a stale generation is refused (`resourceConflict`, zero dispatch).
  - Under the current generation it is accepted.
  - The action then reads as the oracle's `trust.expired` reads it.
  - Both `agent resume` and `human-action resume` of it are refused (`humanActionExpired`, zero
    dispatch), and nothing is sent to the device.
- **`connect`, resumed.** With the device connected, the execution is resumed (`connect.resume`)
  and completed.
  - `human-action resume` of its action and reference then answers the same completed execution,
    as the oracle's `connect.againByAction` records it: the execution, its state, the oracle's Job
    and its state, the Target and the binding revision. Nothing is sent again.
  - A `--selection` is refused (`invalidInput`, zero dispatch).
- **Coverage: `agent.abandon` counted, `human-action.resume` measured but not counted.**
  `job plan|submit|run` and `agent run` are not counted on Windows, because their answers depend on
  the operation (the lead's ruling of 2026-10-04). Comments beside the leaves say the same.
  - `agent.abandon` joins `WINDOWS_MEASURED_LEAVES` (Windows `implemented`). It acts on the existing
    execution alone (`AgentExecutions::abandon`): it checks the generation, moves the record to
    `abandoned` and expires its waiting action, and refuses with `resourceConflict` once the
    execution owns a Job. It never plans or submits, so its behaviour does not depend on which
    operation the execution names.
  - `human-action.resume` stays Windows `partial`, like `agent.resume`. Only its first half is
    independent of the operation: finding the action, the expiry and selection checks, and the
    fresh observation. Once the action resolves, it drives the execution through the same
    admission as `agent run` (`AgentExecutions::drive`, then `submit_for_agent`), so its answer
    depends on the operation.
  - The coverage was regenerated with `arkdeck maintainer contracts export`, and `oracle.json` is not
    re-pinned.

## Found, not changed here (contract gap, every host)

`human-action.resume`'s published result schema has no `nextAction.retryAfter`. `agent.resume`'s
schema has it, and both answer the same agent-execution projection.

- When `human-action resume` resumes an action that is still waiting, the projection says the Job
  is running (`nextAction` `wait`, `retryAfter: "250ms"`).
- The control layer then answers `internalError` ("the result does not conform to the current
  contract"). The CLI reports it as `outcomeUnknown`.
- Swift's oracle records only `agent.resume` for that step, and `human-action.resume` only after
  completion. So this layer measures that sequence, and the gap is reported to the lead, to fix
  through the contract generators.

## Left out

- The oracle's `ambiguous` and `unproven` scenarios through the CLI. The owner-level Windows replay
  covers them.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.
