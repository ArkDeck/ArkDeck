# Remaining Windows work

Updated 2026-10-01 against protected main `f41eb0c9` (#2411), with this PR's flash-bundle
coverage (TASK-XPA-018, `runs/TASK-XPA-018/windows-flash-bundle-coverage-run.md`). Phase S is the software;
phase A is the maintainer's real-host and DAYU200 acceptance (proposal r12, r13: Windows 11 x64
only), written out in order in `docs/design/cross-platform/windows-phase-a-runbook.md`. The table
is refreshed once per milestone, in its own docs commit, not in every slice.

| Operations executable on Windows (/30) | Methods the Windows daemon answers (/105) | GJ software-ready on Windows (/5) | GJ real device on Windows (/5, phase A) | CLI coverage `windows: implemented` (/256) | Client pages (/6 + 1 skeleton) | SPK-3 / SPK-4 / SPK-5 |
| --- | --- | --- | --- | --- | --- | --- |
| 0 (`operation.list` names all 30, none `available`) | 73 answered by a composed owner (13 results, 60 owner refusals); 0 non-conforming; 32 no owner | 0 | 0 (rows `WIN-GJ1-001`..`WIN-GJ5-001` registered `NOT_RUN`, #2399) | 75 (69 `partial`, 2 `notImplemented`, 110 unset) | skeleton done (#2365); Device (#2375) and Settings (#2383) built, Sessions and Job results in History (#2393); Debug, Flash, Viewer, Diagnostics open | host rows run, maintainer rows open / WinUI 3 go (provisional) / go |

Previous refreshes:

- main `cf44fcc8` (#2429): 0 · 73 (12 + 61), 0 non-conforming, 32 no owner · 0 · 0 · 68 · same pages ·
  same spikes.
- main `ba756dfe` (#2420): 0 · 71 (11 + 60), 0 non-conforming, 34 no owner · 0 · 0 · 61 (62 after
  #2425) · same pages · same spikes.
- main `86d2f2b8` (#2409): 0 · 63 (11 + 52), 0 non-conforming, 42 no owner · 0 · 0 · 52 · skeleton,
  Device and Settings · same spikes.
- main `659f6474` (#2378): 0 · 28 (7 + 21), 2 non-conforming, 75 no owner · 0 · 0 · 18 · skeleton +
  Device in progress · same spikes.
- main `66b7474b`, before r12: 0 · 3 by design, not measured · 0 · 0 · 0 · 0 + 0 · not run / not
  run / not run.

How each number is read and measured:

- **Operations executable.** A Catalog operation the Rust CLI runs end to end on Windows through
  the named pipe against the Rust daemon, with a fake HDC or stand-in lane on the device side.
  Plan-only or fixture replay does not count.
  - Measured by `rust/scripts/windows-method-census.py`: the development daemon's `operation.list`
    names all 30 operations and marks none `available`.
  - No Windows HDC tuple is registered. CHG-2026-078 is drafted and waits for the maintainer's
    samples (TASK-WHR-001).
  - Every device operation is therefore refused before admission (`provider hdc is not
    registered`), and no provider lane is composed.
- **Methods answered.** Measured with a client over the named pipe by
  `rust/scripts/windows-method-census.py <arkdeck-agentd.exe>`.
  - It starts a development daemon over a fresh root and sends each of the 105 published methods
    the requests the committed control-frame corpus records for it.
  - It counts a method as answered when a composed owner replies: a result, or that owner's own
    refusal. The owner's refusal covers its validation, a reference absent from the fresh root, or
    a dependency owner it names that is not composed.
  - Owners composed: `jobs, capabilities, mutationAuthority, targets, artifacts, imports, storage,
    workspaceProjects, planning, agentExecutions, humanActions, traceCache`.
  - The census exits 0: no non-conforming answer; #2382 fixed the two of the last refresh.
  - The 32 with no owner:
    - `debug.*` (5), `flash.*` (6) and `recovery.flash-invocation.list`;
    - `runtime.hdc.*` (3), `runtime.bundle.*` (4) and `runtime.tool.*` (5);
    - `control-action.*` (3) and `history.filter.*` (3; #2423);
    - `trace.inspect` and `trace.probe`.
- **GJ software-ready.** Every runbook step of that Golden Journey passes on Windows with the fake
  HDC (exit condition 2 of `docs/design/cross-platform/windows-phase-agent-prompt.md`). None does
  yet:
  - GJ-1's host-side hops are measured: Jobs, reconcile, agent executions, human actions,
    Artifacts and Sessions. Its device hops (adopt, `observe.device@1`,
    `capture.diagnostics@1`) need the registered HDC tuple.
  - GJ-2..5 need their owners and lanes: debug, native deploy, the ArkForge lane's Flash hops,
    and the workspace Jobs. The Import owner is on main (#2397), and a DAYU200 flash bundle now
    publishes on Windows (#2424).
- **GJ real device.** `REAL_DEVICE_PASS` on the current Catalog digest, phase A only. The five rows
  are in `openspec/platforms/windows/conformance-cases.yaml`, all `NOT_RUN`.
- **CLI coverage.** `implementationStatusByPlatform.windows == "implemented"` in
  `openspec/contracts/cli-feature-coverage.json`, generated from
  `rust/crates/arkdeck-cli/src/feature_coverage.rs`.
  - The 75 are the leaves that need no Runtime (`help`, `commands`, `completion`, the capability
    stubs) plus `WINDOWS_MEASURED_LEAVES`:
    - `doctor`, `runtime health`, `operation list|describe|example|validate`;
    - `target list|show|display-name set|clear`;
    - `workspace project register|list|show|update|remove`, `workspace preset
      list|show|update|remove`;
    - `trace cache status`;
    - `job list|show|status|events|timeline|result|evidence|wait|cancel|reconcile`;
    - `agent list|status`, `human-action list|show`;
    - `artifact list|inspect|read|export|quota`, `capability list|inspect`;
    - `runtime storage status|policy|root`;
    - `session list|show|pin|unpin|export preview|export apply|cleanup preview|cleanup apply`;
    - `artifact import hap|native-library|workspace-patch|flash-bundle|inspect|list|release|abort`;
    - `recovery cleanup list` and `cleanup-debt list` (#2425);
    - `trace cache purge` and `diagnostics export` (#2431);
    - `runtime service status|verify|restart|uninstall` (#2411; `install` and `update` are the two
      `notImplemented`).
  - Each measured leaf is run through the real CLI against a development-signed daemon, over a
    root holding recorded Swift state. Each test also asserts that the leaves it measured are
    `implemented` in the manifest the CLI renders:
    - `crates/arkdeck-cli/tests/windows_signed_runtime.rs`;
    - `crates/arkdeck-agentd/tests/windows_{job_store,job_runner,reconcile_agent,artifact_owner,import_owner,mutation_retention,session_owner,workspace_projects}_process.rs`.
  - Ruling 9: a refusal because an owner is not composed stays `partial`. So do:
    - `job plan|submit|run`, `agent run|resume|abandon`, `human-action resume` and `target
      adopt|availability`: they need a Target or HDC;
    - `workspace preset register`: a build, test or signing preset pins a DevEco toolchain or
      credential the Windows daemon does not yet register (a symbol preset registers).
- **Client pages.** The XPA-007 skeleton and the six XPA-020 surfaces (Debug, Flash, Viewer,
  Diagnostics, Settings, Device), each wired to the real Windows daemon.
  - The skeleton is on main (#2365).
  - Built on main: the Device Targets and display names (#2375) and the Settings page with an
    automated accessibility pass (#2383).
  - #2393 added Sessions, Job cancellation and results to History, which is not among the six.
  - Debug, Flash, Viewer and Diagnostics wait for their Golden Journey owners.
- **Spikes.**
  - **SPK-3:** host-side rows run (`runs/TASK-XPA-002/spk-3-20260930-run.md`). The rows that need
    the maintainer are open, and are listed with their commands in the phase A runbook §3: signing
    identity, second account, elevation, remote host, MSIX registration.
  - **SPK-4:** WinUI 3 go, provisional until the maintainer rows (`runs/TASK-XPA-007/spk-4-20260930-run.md`).
  - **SPK-5:** go (`runs/TASK-XPA-005/spk-5-20260930-run.md`).

Open PRs that move these numbers when they land:

| PR | Effect |
| --- | --- |
| #2423 | the History filter owner (`history.filter.*`, 3 methods) |
| #2411 | `runtime service uninstall` stopping the client-started daemon on Windows |
| CHG-2026-078 (TASK-WHR-001..003) | the Windows HDC tuple: operations, GJ-1 device hops and the leaves that need a Target |
