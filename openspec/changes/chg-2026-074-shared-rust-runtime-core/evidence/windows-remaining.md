# Remaining Windows work

Updated 2026-09-30 against protected main `ba756dfe` (#2412), with this PR's Import coverage
(TASK-XPA-018, `runs/TASK-XPA-018/windows-import-coverage-run.md`). Phase S is the software;
phase A is the maintainer's real-host and DAYU200 acceptance (proposal r12, r13: Windows 11 x64
only), written out in order in `docs/design/cross-platform/windows-phase-a-runbook.md`. The table
is refreshed once per milestone, in its own docs commit, not in every slice.

| Operations executable on Windows (/30) | Methods the Windows daemon answers (/105) | GJ software-ready on Windows (/5) | GJ real device on Windows (/5, phase A) | CLI coverage `windows: implemented` (/256) | Client pages (/6 + 1 skeleton) | SPK-3 / SPK-4 / SPK-5 |
| --- | --- | --- | --- | --- | --- | --- |
| 0 (`operation.list` names all 30, none `available`) | 71 answered by a composed owner (11 results, 60 owner refusals); 0 non-conforming; 34 no owner | 0 | 0 (rows `WIN-GJ1-001`..`WIN-GJ5-001` registered `NOT_RUN`, #2399) | 61 (79 `partial`, 0 `notImplemented`, 116 unset) | skeleton done (#2365); Device (#2375) and Settings (#2383) built, Sessions and Job results in History (#2393); Debug, Flash, Viewer, Diagnostics open | host rows run, maintainer rows open / WinUI 3 go (provisional) / go |

Previous refreshes:

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
  - The 34 with no owner:
    - `debug.*` (5), `flash.*` (6) and `recovery.flash-invocation.list`;
    - `runtime.hdc.*` (3), `runtime.bundle.*` (4) and `runtime.tool.*` (5);
    - `control-action.*` (3), `cleanupDebt.*` (2) and `history.filter.*` (3);
    - `trace.inspect` and `trace.probe`.
- **GJ software-ready.** Every runbook step of that Golden Journey passes on Windows with the fake
  HDC (exit condition 2 of `docs/design/cross-platform/windows-phase-agent-prompt.md`). None does
  yet:
  - GJ-1's host-side hops are measured: Jobs, reconcile, agent executions, human actions,
    Artifacts and Sessions. Its device hops (adopt, `observe.device@1`,
    `capture.diagnostics@1`) need the registered HDC tuple.
  - GJ-2..5 need their owners and lanes: debug, native deploy, the ArkForge lane's Flash hops,
    and the workspace Jobs. The Import owner is on main (#2397); its flash-bundle publication waits
    for the Flash archive reader (AF-W1).
- **GJ real device.** `REAL_DEVICE_PASS` on the current Catalog digest, phase A only. The five rows
  are in `openspec/platforms/windows/conformance-cases.yaml`, all `NOT_RUN`.
- **CLI coverage.** `implementationStatusByPlatform.windows == "implemented"` in
  `openspec/contracts/cli-feature-coverage.json`, generated from
  `rust/crates/arkdeck-cli/src/feature_coverage.rs`.
  - The 61 are the leaves that need no Runtime (`help`, `commands`, `completion`, the capability
    stubs) plus `WINDOWS_MEASURED_LEAVES`:
    - `doctor`, `runtime health`, `operation list|describe|example|validate`;
    - `target list|show|display-name set|clear`;
    - `workspace project register|list|show`, `workspace preset list|show`;
    - `trace cache status`;
    - `job list|show|status|events|timeline|result|evidence|wait|cancel|reconcile`;
    - `agent list|status`, `human-action list|show`;
    - `artifact list|inspect|read|export|quota`, `capability list`;
    - `runtime storage status|policy`;
    - `session list|show|pin|unpin|export preview|export apply|cleanup preview|cleanup apply`;
    - `artifact import hap|native-library|workspace-patch|inspect|list|release|abort`.
  - Each measured leaf is run through the real CLI against a development-signed daemon, over a
    root holding recorded Swift state. Each test also asserts that the leaves it measured are
    `implemented` in the manifest the CLI renders:
    - `crates/arkdeck-cli/tests/windows_signed_runtime.rs`;
    - `crates/arkdeck-agentd/tests/windows_{job_store,job_runner,reconcile_agent,artifact_owner,import_owner,mutation_retention,session_owner}_process.rs`.
  - Ruling 9: a refusal because an owner is not composed stays `partial`. So do:
    - `job plan|submit|run`, `agent run|resume|abandon`, `human-action resume` and `target
      adopt|availability`: they need a Target or HDC;
    - `capability inspect`: nothing is issued;
    - `runtime storage root`: not yet measured;
    - `artifact import flash-bundle`: refused at publication until AF-W1;
    - `trace cache purge`, the workspace updates and removals, and preset registration.
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
| #2410 | the flash bundle reader on Windows (`artifact import flash-bundle`'s publication, GJ-4) |
| #2407 | the bundled code-sign helper on the Windows daemon (GJ-3) |
| #2411 | `runtime service uninstall` stopping the client-started daemon on Windows |
| #2414, #2419 | HDC's connect-key injection and replacement stop (GJ-1 device hops, after the tuple) |
| #2415 | human actions resumed across process crashes on Windows |
| CHG-2026-078 (TASK-WHR-001..003) | the Windows HDC tuple: operations, GJ-1 device hops and the leaves that need a Target |
