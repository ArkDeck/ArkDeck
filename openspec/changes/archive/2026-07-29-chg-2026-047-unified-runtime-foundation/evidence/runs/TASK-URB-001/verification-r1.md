# TASK-URB-001 verification closure replay r1

Date:2026-07-29

Classification:`contract` / fake integration. This record is not
installed-HDC, real-device, platform-conformance or `realHardware` evidence.

## Verdict

PR #777 exact head
`5c30a59f88446050cd69cbec62e39476d0588747` was approved by maintainer
`lvye` and merged as
`031ad5a0c7f186c389d5789acfb553e3f37a2ac6`. Its same-revision
`run-r1.md` records all five `URB-*` AC as PASS.

The closure replay was executed on protected main
`9637df189b560af2e27bd65ddbf082aae9ce4621`, after the CHG-046 archive
merge. All five `URB-*` conclusions remain PASS on that exact base. This
record does not itself approve `verified`; that state takes effect only if
the maintainer reviews and merges the verification PR.

## Delivery trust chain

- Proposal #775 exact head
  `de09ffd510080d39e7bd7025c7b03d0dd9226efd` was approved by maintainer
  `lvye` and merged as
  `610af3071a0f1b246a4214f043d0d71383913c98`.
- Implementation #777 exact head
  `5c30a59f88446050cd69cbec62e39476d0588747` was approved by maintainer
  `lvye` and merged as
  `031ad5a0c7f186c389d5789acfb553e3f37a2ac6`.
- Both PRs' required Agent PR, SDD Guard and Swift CI checks were `SUCCESS`.
- The approval/merge facts establish authority. The concrete AC truth remains
  the implementation and closure run evidence.

## Approved evolution after #777

Later protected-main MU deliveries #781, #783 and #786 extended the unified
runtime foundation. Relative to #777, current main changes these original
CHG-047 surfaces:

```text
M Packages/ArkDeckKit/Package.swift
M Packages/ArkDeckKit/Sources/ArkDeckAgentClient/AgentClient.swift
M Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentDaemon.swift
M Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift
M Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCCompatibilityProfile.swift
M Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderAdapters.swift
M Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderContract.swift
M Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift
M Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDaemonContractTests.swift
M Packages/ArkDeckKit/Tests/ArkDeckContractTests/DeviceProviderContractTests.swift
M Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeJobEngineContractTests.swift
M Packages/ArkDeckKit/Tests/ArkDeckEngineCrashFixture/main.swift
```

The original HDC production, endpoint-selection and authorization/security
split files, ADR, governance/change design inputs and pre-existing
HDC/golden/supervisor tests are unchanged from #777. The changed inputs above
are not assumed equivalent: their current behavior is covered by the fresh
focused and full-Swift results below.

Current changed-input blob identities:

```text
f55d0ee3ce472d202eeb70acac1e63164262ceb3  Package.swift
f73bf875e9a984cef7ff0563280ed06c25b0d119  AgentClient.swift
df101a19617eba7af1ffe1e3bc71a887b8d5accf  AgentDaemon.swift
2187ab2c1369edca9c6bf7c9d1700f1a084fee08  AgentDaemonMain/main.swift
72456f72f9667d2a2a00644db468f47911549091  HDCCompatibilityProfile.swift
24aafbcc8bdf14dd96077f876a43133bdd6e137a  DeviceProviderAdapters.swift
f4887989019ec357f7e77ad659e89099d2b41a4a  DeviceProviderContract.swift
6802d11fe28a490c5a6c9b181dc814d071f51c54  RuntimeJobEngine.swift
fe16f1e37b44c977a6575f2418642983fa089bd7  AgentDaemonContractTests.swift
e6ca2052ea28276dce0c554a652bfe6e383a638b  DeviceProviderContractTests.swift
b917578af44e06d031f904d6ed453b4bffc2466d  RuntimeJobEngineContractTests.swift
a674ca2566a6387240ab34cb06cf36c5dceeb8f4  ArkDeckEngineCrashFixture/main.swift
```

## Replay environment

```text
macOS 26.6 (25G72), arm64
Apple Swift 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101)
SDD interpreter: shared repository .venv-sdd, Python 3.14.6 / pinned PyYAML
```

## Commands and results

| Command/gate | Result |
| --- | --- |
| `CI=true swift test --package-path Packages/ArkDeckKit` | PASS, 651 tests / 1 existing opt-in manual sleep/wake skip / 0 failures |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter 'DeviceProviderContractTests\|HDCCompatibilityProfileTests\|AgentDaemonContractTests\|RuntimeJobEngineContractTests'` | PASS, 31/31 |
| temporary replay below via `--filter DiagnosticsAndHAPContractTests/testCHG047SameTargetMutationJobsHaveMaximumConcurrencyOne` | PASS, 2 same-target runnable mutation jobs / 18 fake dispatches / maximum concurrency 1 |
| `scripts/check-sdd.sh` | PASS, 0 errors / 0 warnings / 111 acceptance IDs |
| shared-Python `scripts/test_check_sdd.py` | PASS, 62/62 |
| shared-Python `scripts/test_check_pr_paths.py` | PASS, 50/50 |
| shared-Python `scripts/test_agent_pr_workflow.py` | PASS, 8/8 |
| shared-Python `scripts/test_sdd_runtime_entry.py` | PASS, 33/33 |
| shared-Python `scripts/catalog_gen/test_generate.py` | PASS, 34/34 |
| shared-Python `-m unittest discover -s host_loop -t .` from `scripts/` | PASS, 644 tests / 1 expected failure / 0 unexpected failures |
| `git diff --check` | PASS |

The runtime-entry suite's linked-worktree integration case and host_loop's
loopback-only redirect cases were run outside the filesystem/network sandbox
with their intended temporary Git metadata and local sockets. A parallel
focused Swift rerun inside the sandbox was refused before test execution by
the user module-cache permission boundary and SwiftPM build serialization; the
same four suites were immediately rerun serially outside that boundary and
passed 31/31 as recorded above. These harness constraints do not represent a
product test failure and introduced no product network or device request.

## Deferred mutation-lane replay

The implementation-time plan explicitly deferred an engine-level concurrent
count until a runnable mutation operation existed. Later MU #786 made
`debug.hap@1` runnable, so closure replayed two jobs for target `TGT-1` through
the current `RuntimeJobEngine` and its real `DeviceMutationLaneCoordinator`,
with only the process dispatcher replaced by a delayed fake. Both jobs
succeeded; their 18 dispatch calls had `same_target_max=1`:

```text
URB-JOB-001 mutation_jobs=2 target=TGT-1 total_dispatches=18
same_target_max=1 real_hdc=0 real_device=0
```

For exact reproduction, the following helper and test were temporarily added
to `DiagnosticsAndHAPContractTests`; its existing `makeEngine(dispatcher:)`
parameter was temporarily generalized from `ScriptedDispatcher` to
`any RuntimeProcessDispatching`. The filtered test passed, then every temporary
source change was removed and `git diff` confirmed that the test file again
matched protected main. The replay source is retained here as evidence, not
as a product-test change in this status-only verification PR:

```swift
private final class ConcurrencyTrackingDispatcher:
  RuntimeProcessDispatching, @unchecked Sendable
{
  private let base = ScriptedDispatcher()
  private let lock = NSLock()
  private(set) var maximumConcurrentDispatches = 0
  private(set) var totalDispatches = 0
  private var activeDispatches = 0

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    lock.withLock {
      activeDispatches += 1
      totalDispatches += 1
      maximumConcurrentDispatches = max(maximumConcurrentDispatches, activeDispatches)
    }
    defer { lock.withLock { activeDispatches -= 1 } }
    try await Task.sleep(for: .milliseconds(20))
    return try await base.dispatch(plan)
  }
}

func testCHG047SameTargetMutationJobsHaveMaximumConcurrencyOne() async throws {
  let dispatcher = ConcurrencyTrackingDispatcher()
  let (engine, capabilities, _) = try makeEngine(dispatcher: dispatcher)
  try await installE1Capability(capabilities)
  let first = try await engine.submit(hapRequest(key: "idem-hap-lane-1"))
  let second = try await engine.submit(hapRequest(key: "idem-hap-lane-2"))

  async let firstStatus = engine.run(jobID: first.jobID)
  async let secondStatus = engine.run(jobID: second.jobID)
  let statuses = try await [firstStatus, secondStatus]

  XCTAssertEqual(statuses.map(\.state), ["succeeded", "succeeded"])
  XCTAssertGreaterThan(dispatcher.totalDispatches, 2)
  XCTAssertEqual(dispatcher.maximumConcurrentDispatches, 1)
  print(
    "URB-JOB-001 mutation_jobs=2 target=TGT-1 total_dispatches="
      + "\(dispatcher.totalDispatches) same_target_max="
      + "\(dispatcher.maximumConcurrentDispatches) real_hdc=0 real_device=0")
}
```

## Acceptance and effect boundary

- `URB-PROV-001`:PASS through the current closed
  resolveFacts/action/lower/verify/reconcile `DeviceProvider` method surface,
  both registered adapters, no raw-command request representation, semantic
  verification and fail-closed reconcile contract tests.
- `URB-HDC-001`:PASS through unchanged split production/golden inputs plus
  current compatibility-profile matrices for registered versions, semantic
  variance and explicit malformed/unsupported outcomes.
- `URB-DAEMON-001`:PASS through two-client UDS, single-instance,
  0700-directory/0600-socket, AF_UNIX-only, structural protocol negative,
  daemon-binary liveness and restart-persistence contract tests.
- `URB-JOB-001`:PASS through current durable idempotency, WAL/crash-window,
  zero-redispatch outcomeUnknown recovery, reconcile, mutation admission,
  safe-boundary cancel and full-timeline contract tests, plus the two-job
  runnable-mutation replay above (`18` fake dispatches, same-target maximum
  concurrency `1`).
- `URB-COMPAT-001`:PASS through the 651-test Swift regression and all declared
  script suites.

Closure activity executed contract/fake paths only. It did not intentionally
invoke the installed HDC, address a real device, dispatch device mutation or
destructive work, alter runtime capability state, or claim hardware/platform
support.

If protected main changes any provider/HDC/daemon/job-engine or corresponding
test input before this verification PR merges, the affected replay must be
repeated and recorded rather than inferred.
