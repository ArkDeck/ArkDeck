# TASK-XPA-005 — Windows Job execution composed over the daemon's managed HDC

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. This follows #2453 (the managed HDC owner on
the Windows daemon, behind the HDC tuple gate) and precedes the `probeHDCServer` commandless
lowering and the GJ-1 oracle replays. The lead asked for the composition first, as its own PR,
so that the GJ-2/3 and GJ-4 lanes can build on it.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## What

Until now the Windows daemon composed its managed HDC (`Host.hdc`, admitted only for a registered
Windows HDC tuple by `windows_hdc_gate`) for the Target owners, `runtime.hdc.status` and the HDC
control actions, but every Job path hard-coded `hdc: None`. Now they read the same composition as
macOS:

- **`Host::hdc`** builds on Windows: the `HdcComposition` over `self.hdc` and the Target store,
  with the tool digest the gate admitted and the receive root.
- **The receive root** on Windows is `std::env::temp_dir()\arkdeck-receive`, the account's
  temporary directory (`GetTempPath2`), where macOS uses Foundation's temporary directory.
- **Planner, admitter, runner, reconciler.** The Windows `planner` takes the composition, and so
  does `windows_runner`. The callers pass `self.hdc()`:
  - `job.plan` (through the Flash planner), `job.submit`, `job.run`, `job.reconcile` (runner and
    `JobReconciler`) and `cleanupDebt.continue`;
  - an agent execution's admission, and its owned Job's background run (built from clones, as
    macOS builds it).
- **`job.submit` admits with the capability authority** (`self.authority()`), as macOS does. It
  was `None` on Windows.
- **Agent executions observe Targets** over the composed HDC (`Host::observing`, now on both
  hosts), as macOS does. They observed none.
- **The Flash facts port** probes over the composed HDC (`flash_hdc`), here and in an owned Job's
  run. It was `None`.
- **One accessor, `Host::job_hdc`,** names that HDC and its tool digest for `Host::hdc`, the
  Target observation sources (`hdc_dispatch`, `observing`), `operation.list` and an owned Job's
  background run (`owned_job_hdc`). In a Windows test build it prefers the in-process fake a test
  composed through #2479's seam (`Host::with_test_hdc`, `cfg(all(windows, test))`), so CI2's signed
  test daemon runs Jobs over its fake. The production daemon has no such seam.
- **`operation.list`** is one function for both hosts. On Windows it now asks after the HDC tool's
  identity (`hdc_registered`, `hdc_tool_current`) and the code-sign helper, as macOS does. It
  answered `provider_not_registered` for every HDC operation.

Without a composed HDC (the account daemon, and a development root whose environment names no
registered tuple) every answer is unchanged: device Jobs are refused `provider hdc is not
registered` before admission, with zero dispatch.

## Tests

- `arkdeck-agentd`'s `windows_lifecycle::tests::an_admitted_hdc_is_composed_as_the_managed_server_and_stopped`
  now also checks the Jobs' composition over the admitted stand-in tuple:
  - without a Target store, `operation.list` still reads the HDC provider as unregistered;
  - with one, `Host::hdc` is built over the admitted tool's digest, with a receive root;
  - `operation.list` asks after the tool's identity and reads it current (no
    `tool_identity_drift`).
- Every existing Windows test of the touched crates passes unchanged. They compose no HDC, so
  they still prove the refusals above.

## Left out

- **`probeHDCServer`** still lowers to `checkserver`. Lowering it to the commandless observation
  on a registered Windows tuple (WHR-002's open point) is the next cut, after #2472 and the XPA-005
  adoption PR land.
- **The GJ-1 replays.** `observe.device@1` and `capture.diagnostics@1` replayed end to end through
  the daemon with an in-process fake HDC, and their CLI leaves measured, come with the next cuts.
  They use CI2's shared harness (#2479), whose fake this composition now prefers in Windows test
  builds.
- **Delegated minor decision, pending the next rulings batch.** The Windows receive root is the
  account's temporary directory (`%TEMP%\arkdeck-receive`). The receive argv names it, so it
  reaches the plan digest, as Foundation's temporary directory does on macOS.

## Local targeted checks

See the PR description: the commands, their exits and the logs are recorded there and in the
commit message.

## CI

This is recorded by the next slice.
