# TASK-XPA-010 — GJ-4 Flash run end to end on Windows, against fakes

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice G2 (GJ-4 Flash), part 2.
On main after TASK-XPA-005's Windows Job HDC composition (#2499,
`windows-job-hdc-composition-run.md`), which feeds the composed HDC (in a
Windows test build, the fake given through `Host::with_test_hdc`, #2479) to the planner, the
admitter, the runner, the reconciler and an agent execution's background run. Host: the Windows
11 x64 reference host, non-elevated. No device was contacted, no `hdc` and no `arkforged` ran, and
nothing was flashed. Host tests are not Windows acceptance.

## What

| Where | What |
| --- | --- |
| `arkdeck-agentd` `Host::agent_execution` (Windows) | An agent execution's request is admitted through the Flash admission (`with_flash_admitter`), as `job.submit` admits it and as the macOS Host does (Swift `submitOwned`). It went to the plain Job admitter, so `agent run --operation flash.full-restore@1` answered "not materialized by the Rust Runtime yet". The background run already ran a Flash through the Flash runner. |
| `src/flash_plan_control.rs` | Builds on Windows: a Flash `job.plan` and `job.submit` in each composition (no Flash composition, no lane, a lane without `arkforged`, without an HDC, without the facts port, and with all of them) answer as Swift's daemon answers, nothing admitted. The roots are private directories; the `arkforged` stand-in is an `.exe`. |
| `tests/spawning/flash_execution_control.rs` | Builds on Windows. The Host is the macOS fixture's with an in-process fake HDC answering what the macOS fixture's `hdc` script answers (through `Host::with_test_hdc`), the Runtime USB relations over the fixture census, and the fixture's Job state as the mutation root (`with_mutation_root`). `canonical.full` is planned, admitted, run to `succeeded` (prepare and perform each asked once, a terminal Job never redispatched, reconcile never dispatching), and with the fakes scripted `outcomeUnknown` stays `waitingForRecovery`, is never replayed, and reconciles by observation only. |
| `tests/spawning/flash_socket_control.rs` | Builds on Windows. Each case runs in a copy of the test binary signed with the development signer (`signed_daemon::signed_copy`), serving the Host above on a private pipe; the real CLI reaches it through `ARKDECK_ENDPOINT` and verifies it with `ARKDECK_DAEMON_PATH` and `ARKDECK_DAEMON_SIGNER_SHA256`. Cases: `agent run` (canonical and the `flash.dayu200` alias) and `flash run` to completion; both left unknown and never replayed; and, new on both hosts, `job plan` / `job submit` / `job run` of the oracle's recorded request to completion (then `flash bootloader-status` and `flash prerequisites` read the bound target) and to an unknown outcome never replayed. Each parent checks that its child ran exactly its one case. |

## Coverage

`flash.run`, `flash.bootloader-status` and `flash.prerequisites` join
`WINDOWS_MEASURED_LEAVES`. The shared generic leaves the same test drives (`agent run`, `job plan`,
`job submit`, `job run`) are not counted: by the lead's ruling of 2026-10-04 (with CI2, for
GJ-2/3), a shared generic leaf counts on Windows only once every operation it reaches there
answers as Swift does, and counting them on the Flash evidence would overstate the debug, native,
observe and workspace operations they also reach. The tests that drive them stay. `cli-feature-coverage.json` regenerated with
`arkdeck maintainer contracts export` (Windows implemented 89 -> 92, partial 68 -> 65: `flash.full-restore@1`,
whose target is `flash run`, and the two host reads; `flash.dayu200`, a generic Catalog operation
reached through `job submit`, stays partial); its six oracle pins substituted. The pins on main
still named the coverage before #2465 (50ef81c4…); they are replaced by this coverage's digest.

## Left out

- `flash.device-access` and `flash.lanePlanPreview` through the CLI: they read ArkForge's public
  pipe and the lane's plan previewer, which no fake serves here; `flash.reconcile-alias` and
  `flash.bind-current-loader` replay through the Windows Host and Control already
  (`loader_binding_control.rs`, the hoststore post-flash alias oracle) but are not driven through
  the CLI in this layer.
- The protected Flash recovery broker (`debug.start` / `debug.evaluate`,
  `tests/spawning/flash_broker_control.rs`) and `recovery.flash-invocation.list`: the Host's Flash
  invocation owner (`with_flash_invocations`) is macOS-only.
- The production Windows daemon still installs no executable lane: its lane authority binds the
  managed-control HDC's digest, which only a registered Windows HDC tuple's managed server gives.
- Delegated minor decision, pending the next rulings batch: Flash-specific leaves measured end to
  end against the oracle's fake lane and an in-process fake HDC through the signed test daemon
  count as measured on Windows, as CI2's harness (#2479) measures GJ-2/3; the shared generic
  leaves do not (the lead's ruling of 2026-10-04, above).

## Local checks

See the commit message.
