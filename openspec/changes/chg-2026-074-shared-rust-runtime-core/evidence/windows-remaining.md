# Remaining Windows work

## Current milestone (2026-10-06)

Protected main `d238a55c7b693adc7edbf6314699e920f0ee1e08` includes #2597's host
workspace Session publication repair. Closed host mutations keep their original
complete consumed Runtime authority and require matching durable Job, Journal,
plan and same-SHA tool provenance. Windows reads external-tool fixed PE
FileVersion from the retained executable without a version child. The Runtime's
own compiled package version requires its exact executable path, native identity
and SHA. The existing typed Job reconcile
can settle publication without replaying the operation, changing its outcome or
renewing authority; unknown or incomplete proof still refuses.

Root-verified independent host patch/build/test publications succeeded at
generations 7/8/9. Build HAP/log and test-log bytes were read whole, and the
fixed-input checks exited 0. The three host dispatches used 1007.746156 seconds
and 2,750,419 declared Job Artifact bytes within the unchanged one-round,
40-minute/512-MiB independent budget. Historical build/test publications at
generations 5/6 keep their original outcomes and authority. A separate independent
`debug.hap` smoke succeeded once with publication generation 10 and whole,
hash-checked `debug-hilog.txt`, `install-readback.json` and
`process-readback.json`. Its software checks passed without a UI, device-info,
screenshot or formal/hardware PASS claim. Typed stop then preserved state and
reported a complete drain with no socket. Exact Job/Manifest facts are in
`runs/TASK-XPA-011/windows-workspace-publication-delivery-20261006-run.md`.

The current CLI census is **149 implemented, 11 partial and 2 notImplemented**
of 162 Windows-required features, plus **101 macOS-only** entries. The repair
adds no CLI leaf and changes no count. The current owner/leaf census is
`docs/design/cross-platform/windows-remaining.md`; the older operation/method
totals below are historical measurements, not current availability assertions.

The resumed GJ-1 run on 2026-10-06 achieved `REAL_DEVICE_PASS` with all 88
recorder criteria holding on source
`d238a55c7b693adc7edbf6314699e920f0ee1e08` and Catalog
`c6e92eb252fe7653ed303a9ce34d12635bbc5f71ffb2a54fb8eb1fa3a9b99036`.
Observe's three and capture's six published Artifacts were read whole and
hash-verified before and after restart; the eight missing capture declarations
remain in the inventory. Physical unplug produced Runtime HAR exit 75 and zero
new dispatches; one resume using the fresh status/show reference exited 0, with
all three HAR Artifacts read whole and hash-verified. Typed stop/status (Raw
83/84) exited 0 with complete drain, absent socket and preserved state. The
canonical record is
`docs/design/references/v1.6-goal/gj-headless-rerun-2026-10-06-windows.json`;
the run note is `runs/TASK-XPA-006/windows-gj1-2026-10-06-run.md`.
The earlier user-skipped window remains historical truth.

GJ-2/3/5 remain incomplete. The original paired GJ-2 HAP, GJ-3 signed ARM32
library and pinned rollback fixture remain missing.
Signing and device verification of the repaired WaterFlow HAP remain blocked
on board-trusted debug signing material and preset. The separate smoke does not
replace GJ-5's remaining crash-probe inputs or prove its signed device loop.
AF-W1, the trusted Windows ArkTrace distribution, quiet-host
performance/baseline work and the existing closed service install/update ruling
remain as listed in the current census and phase A runbook.

## Historical milestone (2026-10-04)

Recorded against protected main `955cf537` (#2469). Phase S is the software; phase A is
the maintainer's real-host and DAYU200 acceptance (proposal r12, r13: Windows 11 x64 only),
written out in order in `docs/design/cross-platform/windows-phase-a-runbook.md`. The table is
refreshed once per milestone, in its own docs commit, not in every slice.

| Operations executable on Windows (/30) | Methods the Windows daemon answers (/105) | GJ software-ready on Windows (/5) | GJ real device on Windows (/5, phase A) | CLI coverage `windows: implemented` (/256) | Client pages (/6 + 1 skeleton) | SPK-3 / SPK-4 / SPK-5 |
| --- | --- | --- | --- | --- | --- | --- |
| 0 (`operation.list` names all 30, none `available`) | 94 answered by a composed owner (17 results, 77 owner refusals); 0 non-conforming; 2 request refused; 9 no owner | 0 | 0 (rows `WIN-GJ1-001`..`WIN-GJ5-001` registered `NOT_RUN`, #2399) | 89 (64 `partial`, 2 `notImplemented`, 101 unset) | skeleton and all six built: Device (#2375), Settings (#2383; remote build sources #2474), Debug (#2430), Flash (#2442), Viewer (#2452, with Trace capture and the Trace viewer), Diagnostics (#2464); their device actions are refused until the HDC tuple | host rows run, maintainer rows open / WinUI 3 go (provisional) / go |

Previous refreshes:

- main `f41eb0c9` (#2411, with #2435): 0 · 73 (13 + 60), 0 non-conforming, 32 no owner · 0 · 0 ·
  75 (69 `partial`, 2 `notImplemented`, 110 unset) · skeleton, Device and Settings, Sessions and
  Job results in History (Debug #2430 had landed but was not counted) · same spikes.
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

Landed since `f41eb0c9`: #2423, #2428, #2434, #2437..#2464, #2466, #2469..#2471 and #2474..#2476
(#2435 was counted in the last refresh; #2444, #2445, #2455, #2458 and #2466 are macOS or
toolchain only), among them:

- CHG-2026-078 r2 (#2459), the sanitized HDC and DAYU200 samples (#2456, #2457), the USB census
  (#2471) and its profile mapping (TASK-WHR-003, #2469);
- the HDC lifecycle, managed HDC and control-action owners (#2439, #2446, #2453, #2461), and HDC
  registration over the empty Windows tuple table (#2475);
- the Bootstrap registry, History filter, analyzer, workspace provider and daemon Bundle (#2428,
  #2423, #2450, #2463, #2447, #2451);
- the Flash owners and the Flash host facts replay (#2441, #2462), the debug.hap and
  native-deployment lanes against a fake HDC (#2449);
- the WinUI Flash, Viewer, Diagnostics and remote build sources (#2442, #2452, #2464, #2474);
- rulings 29–82 (#2437, #2460, #2476).

How each number is read and measured:

- **Operations executable.** A Catalog operation the Rust CLI runs end to end on Windows through
  the named pipe against the Rust daemon, with a fake HDC or stand-in lane on the device side.
  Plan-only or fixture replay does not count.
  - Measured by `rust/scripts/windows-method-census.py`: the development daemon's `operation.list`
    names all 30 operations and marks none `available`.
  - No Windows HDC tuple is registered: `WINDOWS_HDC_TUPLES` is empty, and the HDC registration
    built over it refuses every `hdc.exe` (#2475). CHG-2026-078 r2 (#2459) fills the registration
    from the 2026-10-04 samples; TASK-WHR-001 and TASK-WHR-003 are on main, and TASK-WHR-002,
    which registers the tuple, is #2472.
  - Every device operation is therefore refused before admission, and no provider lane is
    composed into Windows Jobs.
- **Methods answered.** Measured with a client over the named pipe by
  `rust/scripts/windows-method-census.py <arkdeck-agentd.exe>` (exit 0).
  - It starts a development daemon over a fresh root and sends each of the 105 published methods
    the requests the committed control-frame corpus records for it. No HDC is admitted there.
  - It counts a method as answered when a composed owner replies: a result, or that owner's own
    refusal. The owner's refusal covers its validation, a reference absent from the fresh root, or
    a dependency owner it names that is not composed (`runtime.hdc.impact-preview|restart` name
    the HDC control-action owner, `runtime.tool.select` the tool-selection owner).
  - Owners composed: `jobs, capabilities, mutationAuthority, targets, artifacts, imports, storage,
    history, workspaceProjects, workspaceOperations, bootstrap, planning, agentExecutions,
    humanActions, controlActions, traceCache, flashHostFacts, deviceAccess, loaderBinding`.
  - No non-conforming answer.
  - The 2 request refused are `runtime.bundle.register` and `runtime.tool.register`. The corpus
    records only macOS paths, which the control layer refuses as not absolute on Windows before
    the Bootstrap owner is reached. Their owner is composed, and `runtime bundle register` is
    measured through the CLI (#2451).
  - The 9 with no owner:
    - `debug.evaluate|probe|start|status` and `debug.template.run`;
    - `flash.reconcile-alias` and `recovery.flash-invocation.list`;
    - `trace.inspect` and `trace.probe`.
- **GJ software-ready.** Every runbook step of that Golden Journey passes on Windows with the fake
  HDC (exit condition 2 of `docs/design/cross-platform/windows-phase-agent-prompt.md`). None does
  yet:
  - GJ-1's host-side hops are measured: Jobs, reconcile, agent executions, human actions,
    Artifacts and Sessions. Its device hops (adopt, `observe.device@1`, `capture.diagnostics@1`)
    need the registered HDC tuple (#2472) and the Windows Job HDC composition.
  - GJ-2..4: the debug.hap and native-deployment lanes run on Windows host code against an
    in-process fake HDC (#2449), and the Flash owners and host facts replay are on Windows (#2441,
    #2462). Those lanes are not yet composed into Windows Jobs over the managed HDC.
  - GJ-5: the workspace provider is composed and `workspace inspect` is measured (#2463). The
    workspace Jobs (build, test, sign, patch and the rest) need the workspace tools of ruling 69.
- **GJ real device.** `REAL_DEVICE_PASS` on the current Catalog digest, phase A only. The five rows
  are in `openspec/platforms/windows/conformance-cases.yaml`, all `NOT_RUN`.
- **CLI coverage.** `implementationStatusByPlatform.windows == "implemented"` in
  `openspec/contracts/cli-feature-coverage.json`, generated from
  `rust/crates/arkdeck-cli/src/feature_coverage.rs`.
  - The 89 are the leaves that need no Runtime (`help`, `commands`, `completion`, the capability
    stubs) plus `WINDOWS_MEASURED_LEAVES`:
    - `doctor`, `runtime health`, `operation list|describe|example|validate`;
    - `target list|show|display-name set|clear`;
    - `workspace project register|list|show|update|remove`, `workspace preset
      register|list|show|update|remove` (`register` #2447), `workspace inspect` (#2463);
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
      `notImplemented`, `update` by ruling 78);
    - `history filter list|save|delete` (#2423);
    - `runtime bundle register|inspect|list|remove` and `runtime tool list|inspect|remove`
      (#2428, #2451);
    - `analyze crash-signature|hilog-summary` (#2450).
  - Each measured leaf is run through the real CLI against a development-signed daemon, over a
    root holding recorded Swift state. Each test also asserts that the leaves it measured are
    `implemented` in the manifest the CLI renders:
    - `crates/arkdeck-cli/tests/windows_signed_runtime.rs`;
    - the owner process tests `crates/arkdeck-agentd/tests/windows_*_process.rs`.
  - Ruling 9: a refusal because an owner is not composed stays `partial`. The 64 `partial` need a
    Target, the HDC tuple or a lane not yet composed into Windows Jobs:
    - `job plan|submit|run`, `agent run|resume|abandon`, `human-action resume`, `target
      adopt|availability|observe`, `device wait|display-name set|clear`;
    - `runtime hdc status|impact-preview|restart`, `runtime tool register|select`,
      `control-action list|show|reconcile`;
    - `debug hap|probe|template run|native deploy`, `input tap|swipe|long-press`, `screen record`,
      `port-forward create|remove`;
    - `flash bootloader-status|device-access|prerequisites|lane-preview|bind-loader|reconcile-alias|run`,
      `recovery flash-invocation list|start|status|evaluate`, `recovery cleanup continue`;
    - `trace capture|inspect|probe`, `analyze trace|trace-summary`;
    - the workspace Jobs: `workspace
      build|test|sign|patch|status|diff|read|checkpoint|revert|isolate|sweep|symbolize` and
      `workspace continuation submit|run`.
- **Client pages.** The XPA-007 skeleton and the six XPA-020 surfaces (Debug, Flash, Viewer,
  Diagnostics, Settings, Device), each wired to the real Windows daemon.
  - The skeleton is on main (#2365).
  - All six are built at macOS parity:
    - Device: Targets and display names (#2375);
    - Settings: an automated accessibility pass (#2383), and remote build sources over Windows
      OpenSSH with Credential Manager (#2474, ruling 68);
    - Debug (#2430), Flash (#2442), Diagnostics (#2464);
    - Viewer, with Trace capture and the Trace viewer (#2452).
  - #2393 added Sessions, Job cancellation and results to History, which is not among the six.
  - A page's device actions stay enabled and say why they cannot run until the HDC tuple and the
    Windows Job HDC composition land. No page is accepted on a real device before phase A.
- **Spikes.** Unchanged since the last refresh.
  - **SPK-3:** host-side rows run (`runs/TASK-XPA-002/spk-3-20260930-run.md`). The rows that need
    the maintainer are open, and are listed with their commands in the phase A runbook §3: signing
    identity, second account, elevation, remote host, MSIX registration.
  - **SPK-4:** WinUI 3 go, provisional until the maintainer rows (`runs/TASK-XPA-007/spk-4-20260930-run.md`).
  - **SPK-5:** go (`runs/TASK-XPA-005/spk-5-20260930-run.md`).

Remaining phase S work, and the open PRs that move these numbers when they land:

| Work | State | Effect |
| --- | --- | --- |
| TASK-WHR-002, the Windows HDC tuple registration (CHG-2026-078) | #2472, open | the gate admits a registered `hdc.exe`: the precondition for every device operation, GJ-1's device hops and the leaves that need a Target |
| The Windows Job HDC composition | in progress | device operations admitted into Windows Jobs over the managed HDC: operations executable, `job plan`/`submit`/`run`, `target adopt`/`availability`, `runtime hdc` |
| GJ-2, GJ-3 and GJ-4 lanes over the managed HDC | in progress | `debug.*`, the Flash invocation and alias owners, `flash run`; GJ-2..4 software-ready |
| GJ-5 workspace tools (ruling 69) | in progress | the workspace Jobs and their leaves; GJ-5 software-ready |
| `trace.inspect`, `trace.probe` | not started on Windows | the last Trace methods with no owner |

Phase A follows phase S: the maintainer's real-host and DAYU200 runs of `WIN-GJ1-001`..`WIN-GJ5-001`
and the SPK-3 and SPK-4 maintainer rows, in the order of the phase A runbook.
