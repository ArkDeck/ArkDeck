# Trace cache ClientKit extraction

Base: protected main `81957589`. TASK-XPA-019 / SPK-8 remain incomplete. Chosen next by Rust
method readiness: the isolated Rust daemon already serves `trace.cache.status` and
`trace.cache.purge` (TASK-XPA-012), so this facade needs no new Runtime method.

| Already on `main` | This slice | Still remaining (TASK-XPA-019) |
|---|---|---|
| ClientKit transport and History filter (#1976), History readers and JobControl (#1982); the Rust owner's `trace.cache.status/purge` | `RuntimeTraceCacheApplicationFacade` — the inventory and purge-report models with their wire projections, the load/purge results, the App-facing provider protocol and facade, the XPC provider and the strict response decoder — moves from Workflows to ClientKit; the daemon-side `RuntimeTraceCacheMaintaining` protocol stays in Workflows | the Device list facade (open PR #1991), ten more Workflows facade files, SPK-8 signed standalone App acceptance, the UI suites per facade |

## What moved and why the edges change

- `Sources/ArkDeckClientKit/RuntimeTraceCacheApplicationFacade.swift` is the former Workflows
  file (a rename in Git) minus the daemon-side protocol; it imports only `ArkDeckCore` and
  Foundation and uses the existing `RuntimeXPCRequestTransport`. There is no re-export shim.
- `Sources/ArkDeckWorkflows/RuntimeTraceCacheMaintaining.swift` keeps
  `RuntimeTraceCacheMaintaining`, the boundary the Swift daemon composes with ArkTrace's
  lease-aware cache service; its values are the ClientKit models.
- `ArkDeckAgentDaemonMain` implements that protocol (`ProductTraceCacheMaintenance`) and so now
  imports ClientKit: `Package.swift` adds the dependency and
  `ArchitectureBoundaryContractTests.allowedImports` adds the edge for this executable
  composition root (AgentDaemon already had it). No library layer gains an edge.
- The App's Settings sources and the App UI runner's `TraceCacheSettingsStateTests` import
  ClientKit beside Workflows (other Settings facades are still in Workflows).
- `RuntimeTraceCacheApplicationContractTests` (provider uses only the typed resource; decoder
  rejects paths and impossible counts) moves to `ArkDeckClientKitTests`;
  `RuntimeTraceCacheControlContractTests` stays with the daemon and imports ClientKit for the
  models.
- `docs/ArchitectureRules.md` records the split.

Behavior is unchanged: the moved code is byte-for-byte the former file apart from its imports
and the protocol that stayed behind.

## Verification

Unified gate (`plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, `ARKDECK_PYTHON` and the planner from a virtual
environment carrying PyYAML 6.0.3 and jsonschema 4.26.0) on `ee35061f`, merge base `81957589`,
2026-09-19 14:21:29–14:25:57 CST: **exit 0**. Lanes: swift, App build-for-testing,
design-system. The SwiftPM full lane ran 2687 tests without failure — among them the moved
`ArkDeckClientKitTests.RuntimeTraceCacheApplicationContractTests` (2), the daemon's
`RuntimeTraceCacheControlContractTests` (3) and `ArchitectureBoundaryContractTests` (15, with
the new `AgentDaemonMain → ClientKit` edge); `run-xcodebuild.sh build-for-testing` reported
`** TEST BUILD SUCCEEDED **` for the App and its UI runner; design-system 83/83; `check-sdd` 0
errors. The log's only `error:` line is xcodebuild's CoreDevice plug-in notice, present in every
build-for-testing run on this host. Log:
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/tracecache-gate.log`,
SHA-256 `4b734fb2c726d496b393e5b9701a95fd20a9b74e61747a50a3cda261894adf9c`. The commit that
records this section changes only this file.

## Not run

- The Settings UI suite through `run-ui-tests.sh`: the host console was locked
  (`IOConsoleLocked = Yes` since about 13:29 CST), so no UI test can drive the App. The App
  build-for-testing lane compiles the App and its UI runner, including
  `TraceCacheSettingsStateTests`.
- Signed standalone Rust App acceptance, installed activation, a device.
