# TASK-XPA-016 — SPK-6 run record: the HDC lifecycle executor's process part

Change: CHG-2026-074-shared-rust-runtime-core@r11. Spike recorded here: SPK-6 (design §J.3), lane
B's executor primitive after the managed server host (`spk-6-managed-server-run.md`, #1930). Host
measurement only — not hardware, platform or conformance evidence (POL-VERIFY-001, POL-MODE-001).
No device was contacted and no HDC executable was launched: every server and client here is a
fake `hdc` compiled from a few lines of C.

Base: protected main `1c0d7273` (#1930). Branch `agent/xpa-016-hdc-lifecycle-executor-20260914`; no
stacking.

## What was missing

`runtime.hdc.restart` is the one M1 method that mutates the host: after the preview, the approval
and the interactive challenge (all lane A's control-action owner), Swift's
`HDCProcessLifecycleExecutor` runs exactly one `hdc -s <endpoint> kill -r` and believes it only
when a strictly newer server generation owns the endpoint afterwards. The Rust daemon had the
runner and the identity proof but nothing that lowers a confirmed lifecycle action, hands the
audit its facts in Swift's order, launches once and re-observes.

## What Swift does

`HDCProcessLifecycleExecutor.execute` (`ArkDeckOpenHarmony/HDCProduction.swift` 1215–1365): argv
`["-s", <endpoint>, "kill", "-r"]` for a restart and `["-s", <endpoint>, "kill"]` for a stop (the
command-family classifier pins both exactly); the actual command (executable path, argv,
endpoint) is persisted by `consumeDispatchAuthorization` *before* `runner.prepare`; the prepared
executable's identity (`HDCServerLifecycleExecutableIdentityReceipt`: authorized path, `/.vol/<dev>/<ino>`
launch path, device, inode, file size, mode, SHA-256) is persisted by `recordLaunchWindowEntry`
*before* the spawn; the command runs with a 15 s timeout; then `postDispatchProbe`
(`HeadlessHDCControlLifecycleDriver.swift` 223–243) re-reads the commandless identity for 12 s every
100 ms and reports a generation only when it is strictly greater than the confirmed one. Exit
zero, no registered failure and an empty stderr are necessary, never sufficient: a restart
succeeds only as `.generation(newer)`, a stop only as `.unavailable`; every other combination is
`outcomeUnknown` with a fixed reason, which the control-action owner reconciles and never
replays. The generation is `startSeconds * 1_000_000 + startMicroseconds`
(`HDCServerProcessIdentityReceipt.stableGeneration`).

## What Rust now does

- `rust/crates/arkdeck-platform/src/process.rs` (macOS): `VerifiedTool::launch_identity()` —
  the tool revalidated, then `ToolLaunchIdentity { authorized_path, inode_launch_path, device,
  inode, file_size, mode, sha256 }` from the retained metadata; refused when the file changed or
  the inode path no longer names it. `VerifiedTool::path()` is public for the actual command.
- `rust/crates/arkdeck-provider-hdc/src/lifecycle.rs` (macOS): `LifecycleAction::{Restart,
  Stop}` with Swift's exact argv; `LifecycleCommand::new(action, endpoint, tool)` — the actual
  command the owner persists first; `PreparedLifecycle::prepare(tool, command, expected_generation)`
  — the identity the owner persists as the launch-window entry — and `launch(self, &LifecycleBudget)`
  (15 s / 12 s / 100 ms by default), which consumes the preparation, runs the command through
  `run_tool` with `OHOS_HDC_SERVER_PORT` named, re-observes the endpoint through
  `LoopbackServerLease` until the deadline (`PostDispatchObservation::Generation(newer)` for a
  restart, `Unavailable` for a stop; anything else keeps looking, the deadline reports nothing),
  and classifies exactly as Swift does: `LifecycleOutcome::Succeeded { resulting_generation }`,
  `Stopped`, or `OutcomeUnknown` with Swift's six reasons (a launch that could not be classified,
  a nonzero exit, a registered failure through `SemanticOutputParser`, unregistered stderr, a
  server state that could not be re-probed, a state that does not match the action, and a restart
  that did not establish a strictly newer generation). `generation(&ServerIdentityReceipt)` is
  Swift's `stableGeneration`. The receipt keeps the termination and both streams.
- Not done here, on purpose: the durable authorization, the dispatch lease and the launch gate,
  the audit chain and the control-action store are lane A's `runtime.hdc.restart` slice; this type
  gives them the actual command before `prepare` and the identity before `launch`, in that order,
  and `launch` takes the preparation by value so a preparation launches at most once.

## Tests

`cargo test -p arkdeck-provider-hdc --test lifecycle` (7/7 in three consecutive runs; its own binary), over a fake `hdc`
compiled at test time: its `-m` server polls a marker file and ends when it appears; its `kill -r`
client writes the marker, waits until the port is free, then starts a new server of the same
executable in its own session (stdio to `/dev/null`, so the runner's capture ends with the client);
`kill` writes the marker only; a compile-time mode makes the client exit 23, write stderr, or do
nothing.

| Test | Proves |
| --- | --- |
| `the_actual_command_and_the_launch_identity_are_swift_s` | the two argv spellings, the executable path, and the identity's `/.vol/<dev>/<ino>`, device, inode, size, mode, digest |
| `a_changed_executable_is_not_prepared` | a byte appended to the tool refuses `prepare` (`PermissionDenied`) |
| `a_confirmed_restart_succeeds_only_with_a_strictly_newer_generation` | `Succeeded` with a generation above the confirmed one, `Generation` observed, exit 0, no output, and a different PID owns the endpoint afterwards |
| `a_confirmed_stop_ends_in_an_unavailable_endpoint` | `Stopped`, `Unavailable` observed, nothing listens afterwards |
| `a_nonzero_exit_leaves_the_outcome_unknown` | exit 23: Swift's "did not exit zero" reason, `Exited(23)`, no observation within the probe budget |
| `unregistered_stderr_leaves_the_outcome_unknown` | a stderr line: Swift's "unregistered stderr" reason, the line kept |
| `a_command_that_changes_nothing_cannot_be_re_proved` | a no-op client, restart and stop: "server state could not be re-probed", the old server still listening |

## Not run, and why

- No real HDC and no device: whether hdc's `kill -r` produces a listener the kernel labels
  `::ffff:127.0.0.1` is the lease's address rule (phase 1); the fake binds plain IPv4.
- A registered failure result on `kill` is not produced: the fake has no registered failure byte
  family for lifecycle, as Swift's fixture has none; the classifier is the ported
  `SemanticOutputParser`, unit-tested in its own module.
- The launch gate, dispatch lease and crash-recovery table (`spk-6-lifecycle` §2.6 of the
  lifecycle map) are the control-action owner's and are not exercised here.
