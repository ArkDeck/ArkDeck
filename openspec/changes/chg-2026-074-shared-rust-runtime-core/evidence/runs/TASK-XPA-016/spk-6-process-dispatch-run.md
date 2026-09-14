# TASK-XPA-016 — SPK-6 run record: the HDC process dispatch on the verified tool runner

Change: CHG-2026-074-shared-rust-runtime-core@r11. Spike recorded here: SPK-6 (design §J.3), the
provider seam of lane B after phases 1–4 (`spk-6-run.md`, `spk-6-tool-runner-run.md`,
`spk-6-shell-channel-run.md`, `spk-6-pty-exchange-run.md`). Host measurement only — not hardware,
platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device was contacted and no
HDC executable was launched: every child is a shell script under a scratch directory or the shared
fake HDC driver.

Base: lane A's #1920 (`agent/xpa-014-observe-device-20260914`, `d37ba041`, which defines
`HdcDispatch`) on protected main `b274093c`; this slice is stacked on it and declares that in its
commit. Branch `agent/xpa-016-hdc-process-dispatch-20260914`.

## What was missing

Lane A's `HdcDispatch` (`arkdeck-provider-hdc/src/operation.rs`) is implemented only by
`FixtureDispatch`, which runs the isolated owner's fixture tool through `run_read_only`: no
environment, `truncated` never set (output past the budget is an exit status −1 receipt), the
combined 8 MiB / 60 s caps of that path, and a note that a registered HDC is never run through it.
SPK-6 phase 2 delivered `VerifiedTool::run_tool` for exactly this seam ("the provider's
`run_read_only_*` path is unchanged until lane A's `HdcDispatch` seam moves onto the runner").

## What Swift does

`DescriptorBoundProcessDispatcher.hdc(resolver:)` (`DeviceProviders/DescriptorBoundProcessDispatcher.swift`
147–158, 318–432): the child environment is the closed allowlist plus `OHOS_HDC_SERVER_PORT` only
when the daemon inherited a valid one (`HDCServerEndpointSelector.inheritedPortChildEnvironment`,
`HDCEndpointSelection.swift` 88–116: an invalid inherited value is dropped, never forwarded); an
exited child is a receipt with its exit status, both streams and `stdoutTruncated` when either
stream went past the capture; a timeout is `outcomeUnknown("process timed out before completion")`;
a signal death is `outcomeUnknown` with `RockchipHostProcessDiagnostics.signalDeath`; a launch,
identity or authorization refusal is `failed("dispatch refused: …")`; any other error is
`outcomeUnknown("dispatch outcome unobservable: …")`. Nothing gates a dispatch on the server's
existence: a server that is gone is the client's own error and exit status, judged by the step.

## What Rust now does

- `rust/crates/arkdeck-provider-hdc/src/dispatch.rs` (macOS): `ProcessDispatch::new(tool,
  inherited_server_port)` implements `HdcDispatch` over `run_tool` with the plan's arguments,
  timeout and per-stream capture, no working directory, and the runner's clean base plus
  `OHOS_HDC_SERVER_PORT` only for an inherited value that is an integer in 1…65535 (Swift
  `validPort`). `Exited` → `Receipt` with the real exit status, both streams, `truncated` and the
  run's duration; `TimedOut` → `Unobservable("process timed out before completion")`; `Signalled`
  → `Unobservable` with Swift's signal-death sentence; `ToolRunError::Refused` (budget, environment,
  identity, launch) → `Refused("dispatch refused: …")`; `ToolRunError::Unobservable` →
  `Unobservable("dispatch outcome unobservable: …")`. `inherited_server_port()` reads the daemon's
  own variable once for the composition. `FixtureDispatch` is untouched.
- Not done here: the swap in `arkdeck-agentd` (`host.rs`, `main.rs`) and the hoststore observe
  replay from `FixtureDispatch::new(tool)` to `ProcessDispatch::new(tool, None)` — two lines lane A
  makes inside its next slice, which moves those stores into `Arc`s (agreed 2026-09-14), or lane B
  after #1920 merges. Cancellation: the trait carries none, so the runner's hook is `|| false`;
  Swift's `RuntimeDispatchCancellationResolution` is lane A's running-cancellation work.

## Tests

`cargo test -p arkdeck-provider-hdc --test process_dispatch` (its own binary; it spawns children),
7/7, plus the two unit tests of `dispatch.rs` (port validation, the signal sentence):

| Test | Proves |
| --- | --- |
| `the_receipt_is_the_child_exit_status_and_both_streams` | exit 3, `out x` / `err`, not truncated, a positive duration |
| `a_stream_past_the_capture_is_truncated_with_the_real_exit_status` | 8 KiB on stdout or stderr against a 4 KiB capture: `truncated`, the first 4 KiB kept, exit status 4 / 0 kept |
| `a_timeout_leaves_the_outcome_unobservable` | `sleep 30` under 2 s: `Unobservable("process timed out before completion")` within 15 s |
| `a_child_killed_by_a_signal_is_a_host_fault` | `kill -KILL $$`: `Unobservable` with Swift's sentence for signal 9 |
| `a_refused_budget_dispatches_nothing` | a zero timeout: `Refused("dispatch refused: …")` and the child's witness file never appears |
| `only_a_valid_inherited_server_port_reaches_the_child` | `8710` and `+8710` reach the child; `0`, `65536`, `port` and none leave it unset |
| `the_shared_fake_driver_answers_through_the_runner` | the observe fixture's driver at its fixed root answers `list targets -v` byte for byte and logs the argv |

## Not run, and why

- No real HDC and no device: the runner's launch through the retained inode and its budget were
  proved in phase 2; this slice maps a plan onto it.
- No Rust replay of an oracle through `ProcessDispatch` yet: that is the swap above.
