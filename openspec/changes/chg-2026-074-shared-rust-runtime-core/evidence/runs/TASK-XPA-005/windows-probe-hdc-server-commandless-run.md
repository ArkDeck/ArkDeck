# TASK-XPA-005 — `probeHDCServer` lowered to the commandless observation on Windows

Change: CHG-2026-074-shared-rust-runtime-core, adopting CHG-2026-078. GJ-1. This layer is stacked
on #2486 (the registered tuple's consumers), first stacked on its branch and then rebased onto
`main` once #2486 merged. It closes WHR-002's open point that the maintainer accepted on
2026-10-04: `probeHDCServer` is ported to the commandless observation in the Windows Job
composition. `checkserver` is never a Windows probe, because it starts a server when none runs.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## What

- **`HdcDispatch::observe_server`** (provider-hdc). This is the commandless server observation
  that a `probeHDCServer` step lowers to, on a dispatch pinned to a registered Windows tuple. It
  launches nothing. Its answer is `ServerObservation::Observed` or `Unknown(reason)`. An
  implementation that has no such observation refuses it (`DispatchFailure::Refused`), so nothing
  is observed.
  - `ProcessDispatch`, on Windows, observes its pinned executable's own listener at the tuple's
    endpoint (`CommandlessIdentity`, the registry's `serverIdentityGeneration`). There is no client
    and no `checkserver`.
  - `DevelopmentHdc` (agentd) puts the observation behind the same gate as its dispatch: once the
    managed server is not the one launched, the observation is refused.
- **`Action::observes_server_commandlessly`** decides the lowering:
  - `probeHDCServer` over a dispatch pinned to a registered Windows tuple is the commandless
    observation;
  - every other dispatch keeps Swift's `checkserver`, so fakes pinned to no tuple, and macOS, are
    unchanged.

  `Action::verify_server_observation` judges it:
  - once that server is observed, the step verifies the tuple's version as both `clientVersion`
    and `serverVersion` (the executable's hash proves it);
  - otherwise the step is unknown, as an unreadable `checkserver` answer is.
- **The plan** (`job_plan.rs`) names the step `"processKind": "commandless"` and
  `"observationFamily": "serverIdentityGeneration"`, with no argv or timeout. A registered tuple's
  plan digest therefore differs from one that names `checkserver`; it stays stable.
- **The run** (`device_run.rs`) calls `observe_server` in place of the process run for that step,
  and reads its verdict. The Journal intent and outcome, the persisted action (`hdc.observeServer`)
  and the timeline (`verified probe-hdc-server ["clientVersion", "serverVersion"]`) are as before,
  and the step publishes no product.

## Tests

- `arkdeck-hoststore/tests/windows_observe_device_commandless.rs`. A dispatch pinned to the c2
  tuple replays the c2 capture (`-v`, `list targets -v`) and the oracle fake's property reads,
  over the oracle's Target adopted at `3.2.0g`:
  - an `observe.device@1` Job succeeds, and its calls are `-v`, the observation, `list targets -v`
    and the two property reads, with no `checkserver`;
  - an observation that cannot prove the server stops the Job after `-v` and the observation, with
    nothing sent to the device;
  - the plan over the pinned dispatch is stable and differs from the unpinned one.
- `arkdeck-provider-hdc/tests/windows_hdc_adoption.rs::the_server_probe_of_a_registered_tuple_is_the_commandless_observation`
  checks:
  - pinned and unpinned dispatches, and which steps are commandless;
  - the process lowering itself is still Swift's `checkserver`;
  - the verdicts;
  - a dispatch with no observation of its own refuses it.
- Every existing test of the touched crates passes unchanged. Their fakes are pinned to no
  Windows tuple, so the GJ-1 oracle replays still see Swift's `checkserver`.

## Left out

- **The managed start's readiness `checkserver`** against its own just-launched server
  (`ManagedHdcServer::start`) stays as #2486 and CHG-2026-078 r3 left it. It is the owned-lifecycle
  start, not a probe.
- **A live run against the registered `hdc.exe`** needs the coordinator's go-ahead (port 8710 is
  shared). It is not run here.
- **Delegated minor decision, pending the next rulings batch.** The plan's step entry for the
  observation (`processKind: commandless`, `observationFamily`) is new Rust plan bytes with no Swift
  counterpart, because Swift's oracles were recorded on macOS with `checkserver`.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.
