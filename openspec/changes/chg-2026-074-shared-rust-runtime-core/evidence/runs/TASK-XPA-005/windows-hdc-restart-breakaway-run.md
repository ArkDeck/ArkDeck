# TASK-XPA-005 — HDC parity, part 2b: a confirmed restart's replacement on Windows

Change: CHG-2026-074-shared-rust-runtime-core. This record covers part 2b (H2b) of the Windows
HDC parity slice, on top of part 2 (#2439). Its scope was approved by the lead on 2026-10-01.

Branch `agent/xpa-005-windows-hdc-restart-breakaway-20261001`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, no HDC or board was used, and no `hdc` was run.
- Nothing installed was read or written.
- No system setting was changed.
- Host tests are not Windows acceptance.

## Why

On macOS the tool runner ends the `hdc kill -r` client's process group. The replacement server the
client starts runs in a session of its own and survives, as in Swift.

On Windows the runner puts the client in a kill-on-close Job with no breakaway. So the server it
starts was ended together with the client's Job, and every Windows restart ended as
`outcomeUnknown`.

## What

| Where | What |
| --- | --- |
| `arkdeck-platform` `windows/process.rs` | `spawn_detaching`: the same suspended, identity-proved spawn into a kill-on-close Job, with `JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK`. The child is still a member and is ended as before; only the processes it creates leave the Job. |
| `arkdeck-platform` `windows/tool.rs`, `tool_process.rs` | `VerifiedTool::run_lifecycle_tool`: `run_tool` over `spawn_detaching` on Windows, and exactly `run_tool` on macOS. After the client has exited, its capture ends within 500 ms (`DETACHED_DRAIN`) with whatever arrived, so a server holding the pipes it inherited cannot hold the run open. Every other tool keeps the Job its descendants cannot leave. |
| `arkdeck-platform` `windows/server.rs` | `LoopbackServerLease::endpoint_held`: whether any process holds a loopback or wildcard listener on the endpoint's port, read from the kernel listener table. It connects to nothing and proves nothing. |
| `arkdeck-provider-hdc` `lifecycle.rs` | The executor launches through `run_lifecycle_tool`. The post-dispatch re-observation now also records `LifecycleReceipt::unproved_listener`: whether, at its end, a listener held the endpoint that the commandless proof could not bind to the tool (Windows only). The outcome rules are unchanged. A replacement becomes the outcome only through the fresh proof. |
| `arkdeck-platform` `windows/process.rs` (flake fix) | `terminate_group` now holds a handle on each Job member before it terminates the Job. Each member is proved to be in the Job after it is opened, so a PID reused since the list was read is never waited for. `kill_and_wait` and `group_drained` also wait for every one of them. A process leaves the Job's active count during its exit, before its own object is signalled, so the count alone could report a tree gone while a grandchild was still ending. That race made `a_deadline_terminates_a_live_child_tree` and the cancellation-drain test fail under load. Before the fix they failed 4 of 6 runs (normal and 8.3 short TEMP); after it they passed 6 of 6. |

## Proof

- `arkdeck-platform/tests/windows_tool_dispatch.rs`:
  - `an_ordinary_run_ends_what_its_child_started_even_after_a_clean_exit`: `run_tool` still ends a
    grandchild that is running when the child exits 0, before it returns. This is the regression
    guard for every other tool.
  - `only_a_lifecycle_run_lets_what_its_child_started_outlive_it`
  - `a_lifecycle_run_is_not_held_by_the_pipes_a_survivor_kept`: its outcome is the client's
    `Exited(0)`, well within the deadline.
  - The existing tree, deadline and cancellation tests pass as before.
  - Every process a test causes is ended by the test, including on a failed assertion.
- `arkdeck-provider-hdc/tests/windows_lifecycle.rs` (the fake `hdc` is the test binary, whose
  `kill -r` starts its replacement detached, inheriting the client's pipes) mirrors the macOS
  lifecycle tests:
  - The actual command and the launch identity: the authorized path, a nonzero volume and file id,
    and the digest.
  - A changed executable is not prepared.
  - A confirmed restart succeeds only with a strictly newer, proved generation. The replacement is
    another PID, is recorded, and has no unproved listener.
  - A replacement the proof cannot bind (`hdc-foreign`, a copy with other bytes) is never adopted
    and is reported: the outcome is `outcomeUnknown` with no observation, `unproved_listener` is
    true, and the server still answers and was never signalled by the executor. The test ends it
    through its marker.
  - A confirmed stop leaves the endpoint unavailable.
  - A nonzero exit, unregistered stderr, and a command that changes nothing each leave the outcome
    unknown.

## Delegated minor decisions, pending the next rulings batch

1. **Lifecycle-only breakaway.** On Windows the HDC lifecycle client runs in a Job that allows
   silent breakaway, so the server `kill -r` starts outlives the client. The reason is macOS
   parity: there the setsid'ed server survives the client's process-group kill. Such a server is
   adopted only through a fresh commandless proof and ended only by `end_proved_process` (#2419).
   Every other tool keeps the no-breakaway Job. (Lead, 2026-10-01.)
2. **Capture end.** A lifecycle client's capture ends 500 ms after the client exited, with what
   arrived.
3. **Unproved-listener report.** A listener that holds the endpoint and cannot be bound to the
   tool is reported in the receipt (`unproved_listener`), read from the listener table without
   connecting. On macOS it is never set, as Swift reports none.

## Gates

The PR description gives this commit's gate output.
