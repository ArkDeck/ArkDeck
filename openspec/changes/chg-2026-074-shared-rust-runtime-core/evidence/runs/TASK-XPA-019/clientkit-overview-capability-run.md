# Overview capability ClientKit extraction

Base: protected main `05861555`. TASK-XPA-019 / SPK-8 remain incomplete. This slice moves
ownership only; it does not make the Overview capability matrix available on the Rust daemon
(see "Rust readiness").

| Already on `main` | This slice | Still remaining (TASK-XPA-019) |
|---|---|---|
| ClientKit transport and History filter (#1976), History readers and JobControl (#1982), Device list (#1991), Trace cache (#1997) | `OverviewCapabilityApplicationFacade` — the matrix models, the online-target projection, the provider protocol and facade, the production provider's reads and decoding, the UI fixture — moves from Workflows to ClientKit; the hidumper row's `debug.template@1` Job stays in Workflows behind a ClientKit protocol the App composes | nine Workflows facade files, the Debug facade (which will absorb the runner seam), SPK-8 signed standalone App acceptance, the UI suites per facade |

## What moved and what stayed

- `Sources/ArkDeckClientKit/OverviewCapabilityApplicationFacade.swift` is the former Workflows
  file (a Git rename, 79% similar). It imports only `ArkDeckCore` and Foundation and reads through
  the existing `RuntimeXPCRequestTransport`. There is no re-export shim.
- It used four Workflows-only things. Each was handled as follows:
  - `DebugXPCReadTransport`/`DebugXPCReadFailure`, a `mapError` wrapper over ClientKit's
    `RuntimeXPCRequestTransport`: the provider now makes the same call itself and maps to
    `OverviewCapabilityReadFailure.transport`. The case name is kept, so the failure texts the
    matrix shows, including `String(describing:)` (`transport("…")`), are unchanged. The request is
    an injectable closure that defaults to that call, as `RuntimeTraceCacheXPCProvider`'s is. This
    lets tests drive the production path without a daemon, so the actor is internal instead of
    private.
  - `TraceRuntimeToolDisposition` (the Provider's `DeviceProviders/TraceRuntimeProbe.swift`): it is
    replaced by the display-only `OverviewTraceToolDisposition`, which has the same four raw values
    (the #1991 precedent is `DeviceAuthorizationPresentation`). An unknown value still reads as
    "Required probe result was omitted". A ContractTests switch over the Provider enum stops
    compiling if the Provider adds a verdict.
  - `DebugTemplateJobExecution.run` with `DebugRuntimeCommandTemplate.windowInventory` and
    `DebugLogJobRunResult`: this is the read-only `debug.template@1` Job whose success is the
    hidumper row. It cannot move. Its request is ArkDeckRuntime's `RuntimeOperationRequest`, and
    ClientKit may import only Core. Its client context is `RuntimeWorkspaceThread`'s, whose
    per-process salt it shares with the Debug workspace. Copying the request into ClientKit would
    fork both. Instead, ClientKit declares `OverviewWindowInventoryJobRunning` and
    `OverviewWindowInventoryJobResult`, which carry only the Job ID, state and `outcomeUnknown`, or a
    failure text. That is exactly what the row renders. The new
    `Sources/ArkDeckWorkflows/DebugWindowInventoryJobRunner.swift` runs the unchanged
    `DebugTemplateJobExecution.run`, and the App composes it:
    `OverviewCapabilityApplicationFacade.make(windowInventory: DebugWindowInventoryJobRunner())`. The
    seam goes away when the Debug facade moves.
- No dependency edge changes. ClientKit → Core is unchanged, and Workflows → ClientKit already
  existed. `Package.swift`, `ArchitectureBoundaryContractTests.allowedImports` and the Xcode
  project are untouched. `docs/ArchitectureRules.md` records the split.
- App changes:
  - `ArkDeckApp/App/ArkDeckApp.swift` composes the runner. It already imported both modules.
  - `ArkDeckApp/Features/HDC/HDCStatusView.swift` imports ClientKit beside Workflows. It renders
    the matrix, and its HDC diagnostics model stays in Workflows.
  - `ArkDeckAppUITests` is unchanged. The Overview UI tests launch with `--ui-test-hdc-diagnostics`,
    whose fixture is unchanged, and no UI copy changes.
- Tests:
  - The five `OverviewCapabilityApplicationFacadeContractTests` move to `ArkDeckClientKitTests`.
    Their source paths follow the file, `make` receives a recording runner, and the fixture test
    also asserts that no Job is run.
  - Two new tests drive the production provider through injected reads:
    - One resolved target: exact requests, runner arguments and rows for four terminal results.
    - Several adopted targets: no `trace.probe` and no Job without a choice. A chosen target is
      probed at its own revision, and mismatched Trace facts keep their text.
  - `ArkDeckContractTests/DebugWindowInventoryJobRunnerContractTests` pins the runner to the Debug
    window-inventory template, the App composition and the verdict mirror.

## Behaviour

A normalized comparison of the production facade with `05861555` has these differences only:

- imports;
- the transport, failure and disposition type names above;
- the injectable request and the internal actor;
- `make(windowInventory:arguments:)`;
- the hidumper Job reached through the runner. It gets the same target, binding revision and
  template, and it still starts concurrently with `trace.probe`.

Request names and parameters are unchanged. `operation.list` and `target.list` are sent without
parameters and `trace.probe` with `{targetId}`. The runner's `job.submit`
(`debug.template@1`/`windowInventory`) and `job.run` are the same code. The decoding, row order,
states and evidence texts are unchanged.

## Rust readiness

The Rust daemon does serve `capability.list` and `capability.inspect`. The route is
`rust/crates/arkdeck-control/src/lib.rs:949` → `capability_resource`
(`rust/crates/arkdeck-agentd/src/host.rs:1128`) → `CapabilityStore::handle`
(`rust/crates/arkdeck-hoststore/src/capability_store.rs:225`). The test is
`rust/crates/arkdeck-hoststore/tests/capability_read.rs::rust_reads_reproduce_the_swift_oracle`
(#1909). This facade never sends them, however. Its "capability" is the Overview's device-tool
matrix (hidumper, hitrace, bytrace, RockUSB Flash). `capability.*` reads Runtime-issued execution
grants (`capabilityId`, uses, lineage). The requests the facade makes are these:

| Request (sender) | Parameters sent | Published request schema | Rust `arkdeck-control` |
| --- | --- | --- | --- |
| `operation.list` (facade) | none | closed `{}`: matches | routed, `lib.rs:558` |
| `target.list` (facade) | none | closed `{}`: matches | routed, `lib.rs:624` |
| `trace.probe` (facade) | `{targetId}` | `{targetId: string}`: matches | not routed: answers `rejected` (`lib.rs:1058`; `read_only.rs::every_unimplemented_method_is_refused_without_entering_the_host`) |
| `job.submit` (runner) | `{requestJson}` for `debug.template@1` | `{requestJson: string}`: matches | routed, but `debug.template@1` is not in `MATERIALIZED` (`rust/crates/arkdeck-hoststore/src/job_plan.rs:30`): "not materialized by the Rust Runtime yet" |
| `job.run` (runner) | `{jobId}` | `{jobId: string}`: matches | routed |

On the result side:

- The `operation.list`, `target.list` and `job.submit` fields the facade reads are published.
- The `trace.probe` schema has `tools: {"type": "array"}` with no item schema, because its corpus
  recorded `tools: []`. The per-tool `tool`/`disposition`/`family`/`rawHelpSha256`/`detail` fields
  the Swift daemon emits (`AgentDaemon.swift:731`) are therefore not pinned.
- The published `job.run` result is closed and has no `timeline` (see the next section).

The standalone Rust App ingress (`rust/crates/arkdeck-agentd/src/app_ingress.rs:145`,
`ARKDECK_APP_INGRESS=history`) admits only:

- `health`;
- `history.filter.*`;
- `job.list`, `job.show`, `job.timeline` and `job.evidence`;
- `artifact.list` and `artifact.read`.

The App therefore reaches none of the five methods above on a pure Rust daemon. By the lane's
ordering rule (facades move as their methods land on the isolated Rust daemon), this facade is not
Rust-ready: `trace.probe` is unrouted and the Job is not materialized.

## Pre-existing defect found (not changed here)

`DebugTemplateJobExecution.run` (`DebugApplicationFacade.swift:824`) decodes the raw `job.run`
result with `DebugRuntimeResponseDecoding.terminal`, which requires `timeline`
(`DebugApplicationFacade.swift:1537`). Since #1733, the Swift daemon's `job.run` has answered the
`arkdeck.job-status/1` projection without `timeline` (`AgentDaemon.swift:2262`,
`RuntimeJobReadProjection.swift:86`). #1733 moved the Debug workspace's `run(jobID:)` to
`RuntimeAppReadResources.statusPresentation` (`DebugApplicationFacade.swift:1292`), but it did not
move this path. The consequence on a live daemon: after the device Job has run, even successfully,
the hidumper row reads `unknown` with "Runtime returned incomplete terminal Debug facts". This
slice keeps that behaviour. The fix belongs to the runner's Workflows path: read the status
presentation after `job.run`, as `run(jobID:)` does.

## Counts

Counted by the dashboard's PYCOUNT rule (`*ApplicationFacade.swift` under each target) at this
head:

- ClientKit has 6 facade files (was 5).
- Workflows has 9 (was 10): RuntimeUpdate, Debug, Flash, RemoteBuildSource, RockchipDeviceAccess,
  RuntimeSupportBundle, Settings, Trace and UIDump.
- ArkDeckApp files importing `ArkDeckWorkflows`: still 19. `ArkDeckApp.swift` composes other
  Workflows facades and the runner, `HDCStatusView.swift` renders the Workflows HDC diagnostics,
  and `OverviewRecordView.swift` uses the Workflows remote-build models.
- ArkDeckApp files importing `ArkDeckClientKit`: 17 → 18.

## Verification

Completed before the gate:

- A static dependency review and the normalized comparison above.
- `check-sdd` reported 0 errors.
- An isolated `swiftc` build of `ArkDeckCore` + `ArkDeckClientKit` (Swift 6, `-Werror
  DeprecatedDeclaration`) with the moved test file as an XCTest bundle ran 7 tests with 0
  failures. It built into this session's scratch directory and not the shared SwiftPM cache.

Unified gate: `plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, run through the host's serialized gate queue with
`ARKDECK_PYTHON` and the planner from a virtual environment carrying PyYAML 6.0.3 and
jsonschema 4.26.0.

- Run: on `b2560d5f`, merge base and `origin/main` `05861555`, 2026-09-19 18:13:19–18:21:28 CST
  (load 14.1 at start). **Exit 0.**
- Lanes: swift, App build-for-testing and design-system (rust not selected).
- SwiftPM full lane: 2698 tests without failure, plus the serialized process-identity race (1) and
  viewer-scale (5) lanes. The `ArkDeckClientKitTests` module ran 67, among them the moved
  `OverviewCapabilityApplicationFacadeContractTests` (7). Also in this lane:
  - `DebugWindowInventoryJobRunnerContractTests` (2);
  - `ArchitectureBoundaryContractTests` (15, matrix unchanged);
  - the Overview consumers `OverviewRunRecordContractTests` (16),
    `HDCDeviceObservationPresentationContractTests` (22) and `DeviceCandidatesContractTests` (12);
  - `DebugApplicationFacadeContractTests` (29).
- App build-for-testing: `run-xcodebuild.sh build-for-testing` reported
  `** TEST BUILD SUCCEEDED **` for the App and its UI runner.
- design-system: 83/83. `check-sdd`: 0 errors.
- Log notes: the only two `error:` lines are xcodebuild's CoreDevice plug-in and CoreSimulator
  notices, which appear in every build-for-testing run on this host. No warning names a changed
  file.
- Log:
  `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/clientkit-overview-gate-r1.log`,
  SHA-256 `c2564a07a5417f05beb389de83d329ef8866849595105672bed7a85e5c20adf6`.

The commit that records this section changes only this file.

## Not run

- The Overview and HDC UI suites (`OverviewRecordUITests`, `HDCStatusUITests` through
  `run-ui-tests.sh`). This slice was not assigned the host's shared UI runway. The App
  build-for-testing lane compiles the App and its UI runner, and the fixture those suites launch
  is unchanged.
- Signed standalone Rust App acceptance, installed activation, a device.
