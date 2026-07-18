# TASK-M1-006 local implementation run

- Date: 2026-07-18 (Asia/Shanghai)
- Base revision: `e29462cda1950a2adfc986d682fe6a158ccf3ae3`
- Environment: macOS arm64; Xcode 26.6 (17F113); Swift 6.3.3.
- Evidence class: local fake-child-process, instrumented contract, temporary-file durability, and
  an initial macOS XCUITest run. The review-remediation addendum below supersedes its UI closure
  claim until the changed UI test suite is rerun successfully. This is **not** real-device,
  hardware-support, platform-conformance, or release evidence.

## Locked inputs

| Input | SHA-256 |
| --- | --- |
| `CORE-2.0.0.yaml` | `07227da529608f26dcbbc8843f1623278b51cb3036cd93e1e9ed4af6f8880aa6` |
| `toolchain-hdc-server/spec.md` | `4f4cb0025e613ee8fc54ce854e541a09c1900037cba05db164eeac4bdd99f22a` |
| `openharmony/profile.md` | `af2b5a5178f8623e89cb5f6f713f25ae6a8479329a16813099544ed219ec7708` |
| `core-conformance.yaml` | `5009f1cd43e17f2b752945ce46e0c842d4249052b0546c4389d2253ec3f63487` |
| CHG-002 proposal | `fd44eb9eb90da950eecd2db3ab79a191c8c9f3ca38222db0d57cdcf045bee099` |
| CHG-002 verification | `c9346c913ef1f91d950f9f0dd36097c6b1674cdc1965d5fd638000c0dc5186` |
| CHG-005 verification | `8c3aff9a59779fc56634ea2d8df0f59cdcb0e3813bf10a470395ef4bc35d6f64` |
| Golden `1.0.0/registry.json` | `b62436ced0cfbb300320a126fed3a182da036e2b72a964ea265a20a8fbdde25a` |

The Golden pack was consumed only through `Bundle.module`; this task did not edit Golden bytes,
the registry, its resource declaration, integration profile, baseline, or conformance files.

## Run record

| Command / check | Result |
| --- | --- |
| `swift format lint <TASK-M1-006 changed Swift files>` | pass (no diagnostics) |
| `swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests` | pass, 9 tests / 0 failures |
| `swift test --package-path Packages/ArkDeckKit` | pass, 181 tests / 1 existing skip / 0 failures |
| `xcodebuild -quiet -project ArkDeck.xcodeproj -scheme ArkDeck -destination 'platform=macOS' -derivedDataPath /private/tmp/arkdeck-m1-006-derived test CODE_SIGNING_ALLOWED=NO` | pass; HDC diagnostics XCUITest executed on macOS |
| `scripts/check-sdd.sh` with isolated `/private/tmp/arkdeck-sdd-python` (`PyYAML==6.0.3`) | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

## Review-remediation addendum 14 — 2026-07-19

This addendum records the current implementation and revalidation after the r4/r5 governance
amendments were merged. The implementation base is
`b01cab60a405704ee59f9f2b11e6eba102b4fa9f`; the TASK-M1-006 worktree was intentionally dirty
while this evidence was recorded. The task is drafted as **blocked**, not done or verified,
because its own verified-integration-profile stop condition is now reached and the current
revision has no passing XCUITest result.

Maintainer direction on 2026-07-19 records this as a legacy task. The canonical status remains
`blocked` because `legacy` is not a governance status and must not be interpreted as completion,
verification, dependency satisfaction, or permission for TASK-M1-007/TASK-M1-008 to proceed.

### Remediation implemented in the approved paths

- Core now has a closed, Codable, immutable `JobToolchainIntent` and exact Job/typed-step binding.
  The production Session composition durably appends and reopens that intent before any probe or
  lifecycle launch; a changed Settings/PATH candidate cannot rewrite the existing Job binding.
- ArkDeckProcess now prepares an open/no-follow, regular executable descriptor, binds its
  device/inode/mode/size/SHA-256 receipt, and launches through a shared atomic gate using the
  stable inode path. Path, symlink, inode, byte, and closed-descriptor substitution plus
  post-validation/pre-spawn Supervisor invalidation all produce an instrumented child launch
  count of zero.
- The HDC production lifecycle path is closed as
  `Core mutateHDCServerLifecycle WorkflowStep -> durable Job intent -> durable HDC intent and
  actual-command receipt -> Supervisor lease/final launch gate -> Process result -> durable
  outcome/reconciliation -> Session final manifest`. The App imports only Core/Workflows and
  reaches this use case through the Session-backed facade; it does not construct argv or import
  Process/OpenHarmony/Storage.
- A launch-window marker now contains the exact executable identity receipt. Reopen of a marker
  without an outcome resolves to `outcomeUnknown`; failed/uncertain entered-launch-window paths
  require post-dispatch observation and reconciliation and cannot publish a confirmed Manifest.
- The lifecycle confirmation is single-use. The existing contract regression found during this
  run was fixed in production dispatch ordering: a second use now returns
  `confirmationNotFound` without reaching typed-step validation or a child launch.
- User-selected executable configuration stores an app-scoped security-scoped bookmark, detects
  stale bookmarks, and retains scoped access across discovery/hash/prepared launch. The package
  reopen contract passes; a signed Sandbox picker/quit/relaunch/actual-execution XCUITest has not
  run successfully and is not claimed below.

No command in this run executed an installed real `hdc`, contacted a device, reached a
non-loopback network endpoint, or performed a real lifecycle/device/destructive action. Process
tests used only system/local fixtures; HDC tests used only the repository fake child.

### Locked inputs and environment

- macOS `26.5.2` (`25F84`), arm64 MacBook Air; Xcode `26.6` (`17F113`).
- `openspec/integrations/openharmony/profile.md` SHA-256
  `af2b5a5178f8623e89cb5f6f713f25ae6a8479329a16813099544ed219ec7708`.
- `openspec/integrations/INTEGRATION-PROFILES.lock.yaml` SHA-256
  `0e7337b4d90b6ded0da77260b0daf58d7daac466e1b4bd587ff5f5f1e57ef8ef`.
- `openspec/platforms/macos/profile.md` SHA-256
  `54bd9b295799cb8d93bf397eeb585f24828463f4f1fce1e59a0693f65369d0bf`.
- `openspec/platforms/PLATFORM-PROFILES.lock.yaml` SHA-256
  `6ed7ae92343f93693555fef4e5831cd363f6d0c5dcb7fbdd4d651d6d506a1212`.
- `openspec/verification/core-conformance.yaml` SHA-256
  `5009f1cd43e17f2b752945ce46e0c842d4249052b0546c4389d2253ec3f63487`.

### Current-revision verification

| Command / check | Result |
| --- | --- |
| `swift format lint --strict <changed TASK-M1-006 Swift files>` | pass, 0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter ProcessExecutorContractTests` | pass, 15 tests / 0 failures |
| `swift test --package-path Packages/ArkDeckKit --filter JobToolchainIntentContractTests` | pass, 4 tests / 0 failures |
| `swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests` | pass, 36 tests / 0 failures |
| `swift test --package-path Packages/ArkDeckKit` | pass, 233 tests / 1 existing skip / 0 failures |
| `xcodebuild test -project ArkDeck.xcodeproj -scheme ArkDeck -destination 'platform=macOS'` | fail before any test method; latest xcresult has 0 passed / 1 runner-initialization failure: `System authentication is running` / authentication cancelled |
| `DevToolsSecurity -status` | `Developer mode is currently disabled` |
| `codesign --verify --deep --strict <Debug ArkDeck.app>` | pass |
| App signature/entitlements | ad-hoc, no Team ID; Sandbox enabled; app-scoped bookmarks enabled; entitlement dump retained in command output |
| App executable SHA-256 | `d59a58bf72a866d806c930defe5d842c7b6cc4434470f83713f8b89b4a9301e5` |
| UI-test runner executable SHA-256 | `9e84db765fbf8ef9afaa803d825110bfde5349e4c1bce762cc6d24305a5e7cdf` |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |
| static production scan for shell APIs and global environment writes | no matches; endpoint environment remains a child-request overlay |

The latest current-revision result bundle is
`~/Library/Developer/Xcode/DerivedData/ArkDeck-atkbftxjoqzlsfaftepljllhytci/Logs/Test/Test-ArkDeck-2026.07.19_00-33-33-+0800.xcresult`.
Its failure is retained as a host authorization blocker, not replaced by the historical 7/7
result. `DevToolsSecurity -enable` is a persistent host security change and was not executed
without explicit operator approval.

### Binary AC disposition

| Evidence ID | Current disposition |
| --- | --- |
| `TEST-AC-HDC-001-01` | contract implementation passes: durable Core intent, reopened immutable binding, exact descriptor/inode/hash launch receipt, and substitution launch count 0 |
| `TEST-AC-HDC-001-02` | blocked: registered `-v` fake-child contract passes, but current signed Sandbox XCUITest did not initialize |
| `TEST-AC-HDC-002-01` | contract passes: one process-backed checkserver observation produces exact-once host-wide fan-out |
| `TEST-AC-HDC-003-01` | contract counters pass; platform/UI closure blocked by current XCUITest and production generation evidence absence |
| `TEST-AC-HDC-003-02` | contract passes with live fake-process PID/tool/argv/endpoint inspection; fabricated field shapes are rejected |
| `TEST-AC-HDC-004-01` | fake-child platform contract passes: exact endpoint argv/environment receipt and unchanged parent environment |
| `TEST-AC-HDC-005-01` | parserGolden passes using only `Bundle.module` pinned bytes and exact registered family/hash |
| `TEST-AC-HDC-006-01` | blocked: no verified production key-access probe and no successful signed Sandbox permission-path XCUITest |
| `TEST-AC-HDC-007-01` / `-02` | bounded/cancel/fault contracts pass with injected probes; blocked for production because no registered selected-device authorization/identity probe or binding revision evidence exists |
| `TEST-AC-HDC-008-01` | domain contract passes; current signed Sandbox UI closure is blocked |
| `TEST-AC-HDC-009-01` | blocked: no verified subserver capability read-only command/family; unknown remains fail-closed and mutation counters remain 0 |
| `TEST-AC-HDC-010-01` | critical/generation/affected-Job race contracts pass with spawn count 0; current UI closure is blocked |
| `TEST-AC-HDC-010-02` | durable typed-step/executor/reopen/finalizer contract passes; production external-server preview remains blocked without verified identity/generation evidence |
| `TEST-AC-HDC-010-03` | contract passes: lease/gate invalidation after final validation and before spawn yields actual child launch count 0 |
| `TEST-MAC-M1-HDC-001` | blocked: fake-child matrix passes, but the required current-revision signed Sandbox XCUITest does not |

### Stop condition and next authorized work

`OPENHARMONY-TOOLS@0.2.0` concretely registers exact golden semantics for `uninstall`,
`checkserver`, and `-v`. It mentions list-target/subserver/key concepts only as candidates and does
not declare an exact executable/argv/effect/raw-family contract capable of producing verified
server identity/generation, selected-device authorization/binding, platform key access, or
subserver capability. TASK-M1-006 explicitly says that when a required probe is not declared by a
verified integration profile, the task stops and an independent integration change is required.

Accordingly, the remaining production probe families must be specified and human-approved in a
separate integration change before this implementation may run them or claim the affected AC.
Independently, the maintainer/operator must explicitly authorize Developer Mode, then rerun the
unchanged required Xcode command and the signed Sandbox picker -> quit -> relaunch -> bookmark
restore -> repository fake executable path. Until both blockers are cleared, TASK-M1-006 cannot
be marked done and this change cannot claim verification, platform conformance, hardware
evidence, or release readiness.

## Review-remediation addendum 13 — 2026-07-18

This addendum records the governance stop requested by the latest review.
`TASK-M1-006` is drafted from **ready** to **blocked**; under the git-native
trust model that state change has no approval effect unless a human maintainer
reviews and merges it. No attempt was made to implement the known forbidden-
path work or to describe the current revision as complete.

### Confirmed structural blockers

1. The App has no production Core `mutateHDCServerLifecycle` Step -> durable
   executor -> Supervisor dispatch -> Session finalizer chain. The internal
   `HDCProcessLifecycleExecutor` and `publishFinalManifest` have no production
   lifecycle caller.
2. Lease consumption, durable launch marking, candidate validation, and
   `posix_spawn` do not share an atomic launch gate. Closing the revocation
   race and pathname TOCTOU requires the currently forbidden
   `ArkDeckProcess` launch boundary and descriptor/inode binding.
3. Production cannot establish reliable server identity/generation or perform
   a registered post-dispatch identity probe; `checkserver` correctly leaves
   impact reliability false.
4. Production authorization/device-binding revision, durable Core Job
   toolchain intent, production key-access/subserver probes, and a lifecycle
   finalization caller are absent. The cancellation-ignoring probe resource
   lifetime and signed sandbox bookmark picker/relaunch/execution chain also
   remain open.
5. The required current-revision XCUITest remains blocked before any product
   assertion by macOS LocalAuthentication (`System authentication is
   running`): the latest xcresult reports 0 passed and one runner-
   initialization failure. Historical 7/7 runs are not current evidence.

These are not ordinary remaining implementation TODOs inside the approved
task boundary. They require new authority over Core/Process/durable Job and
platform/integration surfaces, so the verification policy's stop condition
applies.

### Scope cleanup and newly exposed contract conflict

- The non-HDC `ArkDeckContractTests` XCTestCase and its formatting were
  restored to the exact `main` implementation. The file now differs outside
  the two authorized HDC XCTestCase bodies only where the HDC tests require
  `@testable import ArkDeckOpenHarmony` and Darwin process APIs; the unrelated
  package/app import contract rewrite is no longer retained.
- This exposes an internal task-scope contradiction rather than a product
  regression that the Agent may silently waive. The task explicitly allows
  `Package.swift` to connect Workflows to OpenHarmony/Storage and allows the
  App to import OpenHarmony/Workflows, while its permission for
  `ArkDeckContractTests.swift` is restricted to the two HDC XCTestCase classes.
  Restoring the out-of-scope contract therefore produces exactly the expected
  failures: App imports OpenHarmony/Workflows, and Workflows imports
  OpenHarmony/Storage.
- No task amendment is claimed here. A separate scope/readiness change must
  authorize the exact package/app import contract update and be reviewed and
  merged before implementation resumes.

### Verification at the stop boundary

| Command / check | Result |
| --- | --- |
| `swift test --package-path Packages/ArkDeckKit --filter ArkDeckContractTests` | failed as expected after scope cleanup: 190 tests executed, 1 existing skip, 5 failures in the two non-HDC import-contract methods; all selected HDC suites passed |
| package import-contract failure | Workflows imports OpenHarmony and Storage, which the restored main contract does not permit |
| App import-contract failure | ArkDeckApp/HDCStatusView import OpenHarmony and Workflows, while the restored main contract permits only Core |
| `swift format lint --strict Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkDeckContractTests.swift` | failed on the restored non-HDC main formatting; reformatting that XCTestCase would repeat the unapproved whole-file scope expansion, so it remains a blocking scope-amendment item |
| latest required XCUITest | unchanged from addendum 12: 0 passed / 1 runner-initialization failure before any test method |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

No installed `hdc`, device, external endpoint, or destructive operation was
used. The task must not resume until an approved scope/change resolves the
forbidden production paths and the import-contract authorization, after which
the complete package, SDD, diff, and current-revision XCUITest gates must be
rerun.

## Review-remediation addendum 12 — 2026-07-18

This addendum addresses the two in-scope durable-recovery findings from the
latest review. `TASK-M1-006` remains **ready / request changes**. It does not
close the production Core composition, atomic process-launch, production
identity/authorization/binding, Job durability, platform-probe, or sandbox
end-to-end findings and is not task completion, change verification, platform
conformance, release, real-HDC, or hardware evidence.

### Closed in this addendum

- Durable replay now accepts exactly zero or one lifecycle outcome after a
  valid `actualCommand` and `launchWindowEntered` chain. If the launch marker
  exists but no outcome was persisted, reopen returns the conservative
  `outcomeUnknown("durable lifecycle launch window has no persisted outcome")`
  instead of `nil`. The incomplete chain cannot satisfy completed-lifecycle
  proof and final Manifest publication remains blocked. A file-backed reopen
  fault test covers the five-record
  `preview -> confirmation -> intent -> actualCommand -> launchWindowEntered`
  crash window.
- The internal process executor now returns a typed receipt containing both
  its lifecycle outcome and the exact post-dispatch observation. Every branch
  reached after the launch marker, including nonzero exit, registered semantic
  failure, unregistered stderr, inadequate state, and runner error, carries
  that observation to the Supervisor. Terminal reconciliation persists it as
  a strict `generation` or `unavailable` value separately from the current
  Supervisor actor scope. A failure vector proves that a process-backed
  generation 8 is retained while the concurrently authoritative actor scope
  remains generation 7; reopen no longer silently substitutes the old actor
  generation for the probe result.
- Recovery and Manifest proof require a successful restart observation to
  match its resulting generation and a stopped result to carry an unavailable
  observation. Missing, malformed, or mismatched observation data fails closed
  as `outcomeUnknown` or rejects final publication.

### Findings still open / intentionally fail closed

1. There is still no Session-backed production bridge from Core's registered
   `mutateHDCServerLifecycle` `WorkflowStep` through the internal durable
   lifecycle executor and finalizer.
2. Lease consumption, launch-marker durability, pathname hash verification,
   and `posix_spawn` are not one atomic launch gate. The same forbidden
   `ArkDeckProcess` change is required to bind the executed inode/open
   descriptor and cover a post-validation/pre-spawn fault hook.
3. Production `checkserver` cannot establish server identity/generation and
   there is no registered production post-dispatch identity probe; external
   server recovery therefore remains fail-closed.
4. The App still injects authorization unavailable. No registered production
   authorization adapter persists and rechecks selected-device identity/
   binding revision, and a cancellation-ignoring probe may retain resources
   after the bounded caller returns.
5. `HDCJobToolchainSnapshot` is not persisted in Core Job intent,
   `publishFinalManifest` has no production caller, key-access/subserver
   capability lack production probes, and the bookmark seam lacks a signed
   sandbox picker -> quit -> relaunch -> external-SDK execution test.

### Reverification

No command executed an installed real `hdc`, contacted a device, reached a
non-loopback endpoint, or dispatched a real lifecycle/destructive operation.
All process vectors used the repository fake executable and temporary files.

| Command / check | Result |
| --- | --- |
| `swift format lint --strict <changed TASK-M1-006 Swift files>` | pass, 0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests` | pass, 34 tests / 0 failures; includes launch-without-outcome reopen and generation-8/actor-generation-7 reconciliation vectors |
| `swift test --package-path Packages/ArkDeckKit --filter HDC` | pass, 60 tests / 0 failures |
| `swift test --package-path Packages/ArkDeckKit --filter HDCServerSupervisorContractTests` | included in the HDC aggregate: 19 tests / 0 failures |
| `swift test --package-path Packages/ArkDeckKit` | pass, 229 tests / 1 existing manual sleep/wake skip / 0 failures |
| default-signing `xcodebuild test` with fresh DerivedData/result bundle (`/private/tmp/arkdeck-m1-006-review12.1TgwpL/ArkDeck.xcresult`) | exit 65; App and runner built and used `Sign to Run Locally`, but macOS LocalAuthentication returned `System authentication is running` before any test method |
| `xcrun xcresulttool get test-results summary --path /private/tmp/arkdeck-m1-006-review12.1TgwpL/ArkDeck.xcresult` | `Failed`; passed 0, one runner-initialization failure, no product assertion executed |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

The fresh UI result confirms that the rebased current revision still has no
passing XCUITest closure. Historical 7/7 results remain truthful historical
records but are not substituted for this revision. The task stays `ready`
because the production authority and process-launch blockers above remain
open independently of the local runner initialization failure.

## Review-remediation addendum 11 — 2026-07-18

This addendum addresses the confirmed-failure finalization defect from the
latest review. `TASK-M1-006` remains **ready / request changes**. It does not
close the production Core composition, atomic process-launch, production
identity/authorization/binding, Job durability, platform-probe, or sandbox
end-to-end findings and is not task completion, change verification, platform
conformance, release, real-HDC, or hardware evidence.

### Closed in this addendum

- The durable execution chain now distinguishes proven pre-launch
  nonexecution from an entered process-launch window. After the latest
  Supervisor lease check and before entering the process runner, the internal
  executor writes a single-use `launchWindowEntered` record bound to the
  already durable Step ID, executable, exact argv, and endpoint. Replay
  verifies the strict `intent < actualCommand < launchWindowEntered < outcome`
  order and rejects duplicate or mismatched records.
- `.failed` is now reserved for dispatches that did not enter the durable
  launch window. In particular, a lease invalidated by generation, affected-
  Job, or critical-state change has zero fake-child invocations, no launch
  marker, and no external-effect reconciliation. The Manifest adapter will
  accept such a result only as a nonexecuted Step tuple
  (`skipped/notApplicable/notRun`); an `executed/confirmed/failed` tuple is
  rejected before the write-once publisher.
- Once the launch marker exists, nonzero termination, a registered semantic
  failure, runner error, unregistered stderr, or an inadequate observation is
  never represented as confirmed failure. Nonzero and semantic-failure fake
  vectors both invoke the post-dispatch probe exactly once and produce
  `outcomeUnknown`. The Supervisor synchronously commits a terminal
  reconciliation with `requiresReconcile=true` and the complete observed
  scope; reopen requires that marker plus reconciliation and still blocks
  final Manifest publication.
- Reconciliation metadata uses a dedicated `reconciliationReason` field, so
  it cannot overwrite the historical/outward `outcomeUnknown` reason tuple.
  Reopen therefore verifies and returns the original uncertain outcome rather
  than losing the durable chain to a key collision.

### Findings still open / intentionally fail closed

1. There is still no production bridge from Core's registered
   `mutateHDCServerLifecycle` `WorkflowStep` through a Session-backed durable
   executor/finalization composition. The App remains preview/confirmation
   only.
2. Lease validation, the new launch-window audit, pathname hash verification,
   and `posix_spawn` are not one atomic launch gate. A Supervisor state change
   after lease consumption can still race the spawn, and the executable is
   still reopened by pathname rather than bound to a verified descriptor/
   inode. Closing both findings requires the task-forbidden `ArkDeckProcess`
   path and an approved cross-module design/change.
3. Production `checkserver` cannot establish server identity/generation and
   there is no registered post-dispatch identity probe. External-server
   lifecycle preview therefore remains reliably blocked.
4. The App still injects authorization unavailable; no registered production
   authorization adapter persists or rechecks selected-device identity/
   binding revision. A cancellation-ignoring probe may also retain resources
   it owns after the bounded caller returns.
5. `HDCJobToolchainSnapshot` is not persisted in a Core Job intent,
   `publishFinalManifest` has no production caller, and key-access/subserver
   capability have no production platform probes. Bookmark code lacks a
   signed sandbox picker -> quit -> relaunch -> external-SDK execution test.

### Reverification

No command executed an installed real `hdc`, contacted a device, reached a
non-loopback endpoint, or dispatched a real lifecycle/destructive operation.
All mutation vectors used the repository fake executable and temporary files.

| Command / check | Result |
| --- | --- |
| `swift format lint --strict <changed TASK-M1-006 Swift files>` | pass, 0 diagnostics |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests` | pass, 33 tests / 0 failures; includes pre-launch Manifest rejection and post-launch nonzero/semantic reconciliation vectors |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDC` | pass, 59 tests / 0 failures |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCServerSupervisorContractTests` | pass, 19 tests / 0 failures |
| `CI=true swift test --package-path Packages/ArkDeckKit` | pass, 212 tests / 1 existing manual sleep/wake skip / 0 failures |
| default-signing `xcodebuild test` with two fresh DerivedData/result bundles plus one `test-without-building` retry | build and `Sign to Run Locally` succeeded; all three runners failed before any test method because macOS LocalAuthentication reported `System authentication is running`; current-revision UI result remains a recorded automation deviation, not a pass |
| `xcrun xcresulttool get test-results summary --path /private/tmp/arkdeck-m1-006-review11-retry.SZ4KWo/ArkDeck-retry2.xcresult` | `Failed`; total 1 runner-initialization failure, passed 0; no product assertion executed |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

The three current-runner failures do not rewrite addendum 10's truthful 7/7
historical result, but they also cannot be used as current-revision UI closure
evidence. The task remains `ready` independently because the production
authority and launch-atomicity blockers above are still open.

### Post-main-rebase verification

The detached worktree was rebased from `e29462cda1950a2adfc986d682fe6a158ccf3ae3`
to local/main `1f7c10e4fe266c27866e7cec79be8160c1e5ce53` on 2026-07-18. All tracked
and untracked TASK-M1-006 changes were restored from a temporary Git stash;
`tasks.md` auto-merged without conflict and retains main's TASK-M1-009
completion record alongside this task's unchanged `ready` status.

| Post-rebase check | Result |
| --- | --- |
| `CI=true swift test --package-path Packages/ArkDeckKit` | pass, 228 tests / 1 existing manual sleep/wake skip / 0 failures; includes main's 16 diagnostics tests and all 59 HDC tests |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

## Review-remediation addendum 10 — 2026-07-18

This addendum records the next in-scope security remediation and current-
revision reverification. `TASK-M1-006` remains **ready / request changes**; it
is not task completion, change verification, platform conformance, release,
real-HDC, or hardware evidence.

### Closed in this addendum

- Lifecycle audit authority is no longer a public construction surface.
  `HDCServerLifecycleAuditEvent`, its store protocol, the actual-command value
  and authorizer, and the Supervisor audit-store initializer are package-bound;
  the durable adapter's initializer, replay/finalization helpers, manifest
  confirmation, and adapter errors are internal to `ArkDeckWorkflows`. The App
  can obtain only the safe public `HDCSessionDiagnosticsBootstrap` composition.
  A public Swift symbol-graph extraction contains none of the event/store,
  authorizer, durable-adapter, or injectable-initializer symbols.
- Terminal reconciliation no longer suspends the Supervisor actor. The final
  scope check, synchronous durable full-sync reconciliation commit, endpoint
  state application, and outward result occur in one actor turn. Existing
  intent/outcome asynchronous fault seams remain. A regression sink that
  would re-enter on the old asynchronous reconciliation path now proves the
  queued generation-9 observation runs only after commit/application and is
  never overwritten by generation 8.
- Final manifest publication now consumes the durable lifecycle outcome. The
  related manifest Step must be the Core-registered
  `mutateHDCServerLifecycle` kind with the exact Step ID, destructive/
  at-safe-boundary/none policies, typed action/endpoint/generation/ownership/
  scope/confirmation arguments, empty compensation linkage, and an
  `executed` + `confirmed` semantic result matching the durable outcome. The
  Job terminal status must be `succeeded` for succeeded/stopped or `failed`
  for failed. `outcomeUnknown` is rejected before the write-once publisher and
  remains a recovery condition. Negative tests cover action mismatch,
  skipped/not-run, semantic mismatch, Job-status mismatch, and unknown outcome;
  the positive test includes a matching durable Core Step intent/outcome and
  finalized Job journal.

### Findings still open / intentionally fail closed

1. The App still has no production composition that dispatches Core's
   registered `mutateHDCServerLifecycle` `WorkflowStep` through the internal
   durable process executor. UI preview/confirmation therefore remains
   non-mutating. This needs an approved cross-module authority design rather
   than reopening the audit/executor capability.
2. Dispatch-lease consumption and pathname hash revalidation still precede
   `FoundationProcessExecutor`'s `posix_spawn`. The shared atomic launch gate,
   post-validation/pre-spawn fault hook, and descriptor/inode-bound execution
   require the task-forbidden `ArkDeckProcess` path and a separate approved
   change.
3. The production server probe remains `checkserver`; it cannot establish a
   server identity/generation and no registered post-dispatch generation probe
   exists. External-server impact preview correctly stays blocked until an
   integration change registers a legal identity family.
4. There is no production process-backed authorization probe or selected-
   device binding revision recheck. A cancellation-ignoring implementation can
   still retain resources it owns after the caller's bounded workflow returns;
   the production adapter/resource lifetime and TASK-M1-007 binding work remain
   open.
5. `HDCJobToolchainSnapshot` is not yet a durable Core Job intent, and the
   lifecycle finalization adapter has no production caller. Key-access and
   subserver capability also lack registered production read-only probes.
   Bookmark code/tests exist, but signed sandbox file-picker selection of an
   external SDK followed by App relaunch remains unexecuted end to end.

### Reverification

No command executed an installed real `hdc`, contacted a device, reached a
non-loopback network endpoint, or dispatched a real lifecycle/destructive
operation. Child-process tests used only the repository fake executable and
ephemeral loopback fixture listener.

| Command / check | Result |
| --- | --- |
| `swift format lint --strict <changed TASK-M1-006 Swift files>` | pass, 0 diagnostics |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDC` | pass, 58 tests / 0 failures |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCServerSupervisorContractTests` | pass, 19 tests / 0 failures; includes terminal-commit re-entry fault |
| `CI=true swift test --package-path Packages/ArkDeckKit` | pass, 211 tests / 1 existing manual sleep/wake skip / 0 failures |
| `swift package dump-symbol-graph --minimum-access-level public --skip-synthesized-members` plus targeted `rg` | pass; zero public symbol matches for lifecycle audit event/store, actual-command authorizer, durable adapter/confirmation/error, or `init(auditStore:)` |
| default-signing `xcodebuild test` with fresh DerivedData/result bundle | pass; `Sign to Run Locally`, actual window and test methods executed, 7/7 passed |
| `xcrun xcresulttool get test-results summary --path /private/tmp/arkdeck-m1-006-review10.dXkgy9/ArkDeck.xcresult` | `Passed`; total 7, passed 7, failed 0, skipped 0 |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

The successful current-revision XCUITest supersedes addendum 9's two recorded
automation-initialization failures for UI-suite result purposes; those earlier
failures remain truthful historical deviations and are not deleted.

## Review-remediation addendum 8 — 2026-07-18

This addendum records remediation of the latest review. `TASK-M1-006`
remains **ready / request changes**: the changes below do not close the
cross-module production lifecycle, process-launch atomicity, identity probe,
or Job durability findings and are not task completion, change verification,
platform conformance, release, or hardware evidence.

### Closed or materially remediated in this addendum

- Impact scope hashing now encodes a versioned, typed canonical JSON object
  with sorted keys and real JSON array/string boundaries before SHA-256.
  `affectedJobs=["a,b"]` differs from `["a","b"]`, and the same boundary is
  enforced for other-client identifiers. A confirmation created for the
  former Job set is rejected as stale after the latter set replaces it; the
  executor invocation count remains zero.
- A successful/stopped process outcome that becomes stale while the durable
  outcome append re-enters the Supervisor is no longer returned or broadcast
  as success. The historical generation-8 process result remains in the
  outcome record, a separate durable reconciliation record captures observed
  generation 9/health/ownership, and callers plus affected recipients receive
  `outcomeUnknown` with `requiresReconcile=true`. The adapter test closes and
  reopens the audit writer before replaying the reconciliation fields.
- A read-only `checkserver` result no longer manufactures `.external`
  ownership. Healthy unidentified observations use `.unknown` ownership and
  unknown generation evidence. Tool identity failure, launch failure,
  registered failure, mismatch, and unknown output are probe diagnostics, not
  evidence of an unavailable/external server; they create no state from
  nothing and revoke identity/generation claims on an existing state. An
  unidentified healthy observation also cannot retain a prior managed claim.
- Authorization policy now carries a per-probe timeout, overall timeout, and
  polling interval. A single-assignment race lets the workflow return on its
  deadline even when the probe ignores cancellation; late `ready` values
  cannot win after timeout/cancellation. This closes the bounded-workflow
  defect only; it does not invent a production device-identity probe.
- User-selected executables are persisted as app-scoped security-scoped
  bookmarks, with stale-bookmark refresh and resolved-path binding. The
  capability follows the discovered `HDCCandidate`; discovery/hash and the
  complete process-execution await window pair `startAccessing`/`stopAccessing`.
  A standard SwiftUI file importer stores the bookmark and rebuilds the
  read-only/Session diagnostics composition. Persisted pathname strings alone
  are no longer treated as relaunch authority. A close/reopen contract test
  verifies bookmark recovery and capability propagation to the candidate.
- The scheme's product `LaunchAction` is restored to
  `ignoresPersistentStateOnLaunch="NO"`; only the HDC UI-test registration
  remains in that file. The UI-test launcher continues to isolate its own
  persistent state and the default-signing suite still creates a window.

### Findings still open / intentionally fail closed

1. Confirmed lifecycle still has no production Core
   `mutateHDCServerLifecycle` `WorkflowStep` composition. The internal HDC DTO
   and executor remain test-only for dispatch; the App can preview/confirm but
   cannot reach a production mutation use case. Closing this requires an
   approved cross-module authority design instead of reopening a public
   executor or authorizer factory.
2. Lease consumption and pathname hash revalidation still precede the actual
   `posix_spawn`. A shared post-validation/pre-spawn gate and launch bound to
   the verified descriptor/inode require the task-forbidden
   `ArkDeckProcess` implementation and its requested fault hook.
3. The registered production probe is still only `checkserver`, which has no
   process/server identity or generation. External-server preview remains
   blocked, and no production post-dispatch generation probe exists. An
   identity family must be approved in the integration profile before code can
   claim `AC-HDC-010-02` closure.
4. Authorization now has real time bounds but still lacks a registered
   process-backed probe and selected-device identity/binding revision recheck.
   Device binding is TASK-M1-007 scope and no raw family may be invented here.
5. `HDCJobToolchainSnapshot` is still a diagnostics value rather than an
   actual Core Job intent persisted through the Session store. The App's
   diagnostics directory is not `SessionStore.createSession` closure and
   `publishFinalManifest` still has no production finalization caller. This
   needs the forbidden Core/Storage/workflow composition.
6. Bookmark creation, stale refresh, scoped discovery/hash/launch, and the
   standard picker are implemented and contract-tested, but the current UI
   suite does not automate a user-selected external SDK executable across an
   App relaunch. Therefore the code remediation is not represented as complete
   end-to-end sandbox platform evidence.
7. Key-access and subserver capability remain fixture/presentation state. The
   integration/platform profiles register no legal production probes for
   them, so their existing enum/UI tests do not close their platform ACs.

### Reverification

No installed `hdc`, real device, external network endpoint, or destructive
server/device operation was used. Child-process tests used only the repository
fake executable.

| Command / check | Result |
| --- | --- |
| `swift format lint --strict <changed TASK-M1-006 Swift files>` | pass, 0 diagnostics |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDC` | pass, 52 tests / 0 failures |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCServerSupervisorContractTests` | pass, 17 tests / 0 failures |
| `CI=true swift test --package-path Packages/ArkDeckKit` | pass, 205 tests / 1 existing skip / 0 failures |
| `xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/arkdeck-m1-006-xcodebuild-review8.3cAldG/DerivedData -resultBundlePath /private/tmp/arkdeck-m1-006-xcodebuild-review8.3cAldG/ArkDeck.xcresult test` | pass, default signing and no build-setting override; window observed; 7/7 passed |
| `xcrun xcresulttool get test-results summary --path /private/tmp/arkdeck-m1-006-xcodebuild-review8.3cAldG/ArkDeck.xcresult` | `Passed`; total 7, passed 7, failed 0, skipped 0 |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

## Review-remediation addendum 7 — 2026-07-18

This addendum addresses the newly reported post-dispatch generation and
authorization-cancellation defects. `TASK-M1-006` remains **ready / request
changes**; none of the remaining production-authority or platform findings is
represented as closed.

### Closed in this addendum

- A restart result must now establish a generation strictly greater than the
  typed step's expected generation. Both the internal process lifecycle
  executor and the Supervisor reconcile guard reject a lower or equal result
  as `outcomeUnknown`, preserving the current endpoint state. The fake-child
  test covers expected generation 7 with post-dispatch generation 6.
- The Supervisor reconciles the complete current impact scope (generation,
  ownership, affected recipients, other-client state, impact reliability, and
  critical gate) before it records a successful/stopped executor result. If a
  newer observation arrives after the post-dispatch probe but before this
  reconciliation, the result is durably `outcomeUnknown` and state generation
  9 remains intact instead of being rolled back to 8.
- The same scope gate is repeated after the asynchronous durable outcome
  append. A deliberate generation-9 observation re-entered from the audit
  sink leaves current state at 9; the already-durable generation-8 outcome is
  preserved as the historical process result and cannot overwrite newer
  Supervisor state.
- `HDCAuthorizationWorkflow` now checks cancellation again after `await
  probe(attempt)`. A deliberately cancellation-uncooperative probe that later
  returns `ready` produces `.cancelled`, never a late `.ready` result.

### Findings still open / intentionally fail closed

1. Confirmed lifecycle has no production execution composition. This remains
   blocked rather than reopening a public executor factory: the durable
   authorizer is implemented in `ArkDeckWorkflows`, which depends on
   `ArkDeckOpenHarmony`, while the only safe process executor is internal to
   `ArkDeckOpenHarmony`. Exposing a public factory that accepts an open
   authorizer/lease protocol would recreate the previously closed fake-audit
   process-launch path. A production composition requires an approved
   cross-module authority design, plus the still-missing identity-backed
   post-dispatch generation probe; the App therefore remains confirmation-only
   and fail closed.
2. Lease consumption still precedes `posix_spawn`, and pathname SHA-256
   revalidation remains TOCTOU. The shared launch gate, descriptor-bound spawn,
   and requested post-consume/pre-spawn fault hook require the forbidden
   `ArkDeckProcess` implementation.
3. `checkserver` remains the sole production server probe and correctly yields
   unknown generation/unreliable impact. No approved identity-backed external
   generation probe exists, so normal App external-server preview/confirmation
   remains blocked.
4. Maximum attempts does not impose a deadline on an uncooperative probe.
   There is no registered process-backed authorization probe or TASK-M1-007
   binding identity/revision recheck; the cancellation fix alone is not a
   production authorization-workflow closure.
5. Job-intent snapshot durability, security-scoped bookmarks, key-access
   platform diagnostics, and subserver capability probing remain outside this
   task's allowed Core/Storage, entitlement, and integration-profile scope.

### Reverification

No installed `hdc`, device, external network endpoint, or destructive server
operation was used.

| Command / check | Result |
| --- | --- |
| `swift format lint <changed TASK-M1-006 Swift files>` | pass, 0 diagnostics |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests` | pass, 25 tests / 0 failures; includes strict post-dispatch generation and cancellation-after-await faults |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCServerSupervisorContractTests` | pass, 15 tests / 0 failures; includes lower-generation, post-probe, and durable-outcome-append reentrancy faults |
| `CI=true swift test --package-path Packages/ArkDeckKit` | pass, 200 tests / 1 existing skip / 0 failures |
| `xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/arkdeck-m1-006-xcodebuild-review7/DerivedData -resultBundlePath /private/tmp/arkdeck-m1-006-xcodebuild-review7/ArkDeck.xcresult test` | pass, default signing/no override; `xcresulttool` reports 7 total / 7 passed / 0 failed / 0 skipped |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |
| static changed-path scan for shell APIs, global env writes, `spawn-sub`, `killall-sub`, and a real HDC binary path | no matches; Golden test has `Bundle.module` only (its `#filePath` use locates the local fake executable, not Golden data) |

The regular Xcode invocation initially could not overwrite a pre-existing shared DerivedData
artifact under the sandbox. The isolated temporary DerivedData run above passed and is the
verification result. After Xcode created the user-level Swift cache, Swift tests were run outside
the sandbox solely to access that cache. No production or test command executed an installed HDC,
connected to a device, bound a network port, or performed a destructive device action.

`scripts/check-sdd.sh` initially lacked PyYAML in every available local interpreter. After the
user expressly authorized dependency download, `PyYAML==6.0.3` was installed only into the
isolated `/private/tmp/arkdeck-sdd-python` environment; it is not a repository artifact.

## Instrumented observations

- The dedicated `ArkDeckFakeHDCFixture` was launched as a real local child process for success,
  registered failure, unknown, healthy/version, crash, slow, timeout/hang, oversized-output, and
  endpoint-isolation vectors. No vector became implicit success.
- The process-backed `checkserver` probe drove one shared-endpoint health event to both recipients;
  the existing supervisor contract tests verify exact-once generation/health fan-out, and external
  / unknown automatic failure records zero lifecycle audit and dispatch calls.
- Explicit endpoint `127.0.0.1:19710` was observed only as the fake child environment port while
  the parent `OHOS_HDC_SERVER_PORT` value remained unchanged.
- Authorization probe counters showed bounded ready (2 probes), timeout (2 probes), and denied
  paths. Key-access was asserted as a diagnostic state; the earlier evidence did not inject a
  lifecycle counter into that path and must not be read as a measured zero. Authorization and
  channel protection remain independent; TCP is presented as unverified/unprotected absent
  versioned evidence.
- Subserver capability is read-only (`supportedReadOnly` / `unsupported` / `unknown`). The initial
  UI-only absence assertion was structural; the review-remediation addendum records the subsequent
  fake-child argv instrumentation instead.
- The confirmed fake lifecycle restart persisted preview, confirmation, typed intent, actual
  executable/argv/endpoint, and outcome under one correlation. The store was closed and reopened:
  5 records replayed; the selected filtered run emitted
  `sha256=ae88b3b1be42045982e2bb244f7b0fa440f99c652c6fdb62268dbbea5ee84478`.
  The final full-suite execution independently repeated the replay assertion and emitted
  `sha256=23cb9ff4db668e3cd526af3b9e26942fd0a2f30ed07e7d191a81e03b88a5b717`;
  the values differ because each test run creates a fresh correlation and Step UUID.
  Its manifest-compatible confirmation retained the same related Step ID and scope hash.

## Acceptance conclusion

| Test ID | Result | Evidence |
| --- | --- | --- |
| `TEST-AC-HDC-001-01` | pass | immutable job toolchain snapshot test |
| `TEST-AC-HDC-001-02` | historical pass; current UI rerun pending | diagnostics XCUITest exposes all fields and unknown/unverified values |
| `TEST-AC-HDC-002-01` | pass | fake-child `checkserver` host-wide fan-out |
| `TEST-AC-HDC-003-01` | historical pass; current UI rerun pending | external/unknown automatic lifecycle count is 0; original UI had no dispatch control |
| `TEST-AC-HDC-003-02` | pass | absent endpoint plus PID/tool/endpoint launch evidence gate |
| `TEST-AC-HDC-004-01` | pass | fake child environment overlay with unchanged parent environment |
| `TEST-AC-HDC-005-01` | pass | Bundle-module registered Golden semantic evaluation and raw failure preservation |
| `TEST-AC-HDC-006-01` | historical pass; current UI rerun pending | key-access diagnostic + original XCUITest; no detached lifecycle-counter claim |
| `TEST-AC-HDC-007-01` | pass | bounded unauthorized-to-ready transition |
| `TEST-AC-HDC-007-02` | historical pass; current UI rerun pending | distinct denied/timedOut state and non-destructive retry text |
| `TEST-AC-HDC-008-01` | historical pass; current UI rerun pending | authorized TCP stays `unverifiedAssumeUnprotected` with warning |
| `TEST-AC-HDC-009-01` | historical pass; current UI rerun pending | read-only subserver capability and no spawn/killall controls |
| `TEST-AC-HDC-010-01` | historical pass; current UI rerun pending | critical Job/Step/safe-boundary blocks dispatch and is shown by XCUITest |
| `TEST-AC-HDC-010-02` | historical pass; current UI rerun pending | impact fields, confirmation requirement, durable audit/reopen, host-wide broadcast |
| `TEST-AC-HDC-010-03` | pass | post-confirmation generation/affected-Job drift creates a fresh preview and blocks dispatch |
| `TEST-MAC-M1-HDC-001` | pass | real local fake-child matrix; no hardware/network/device claim |

Residual risk: the UI is deliberately presentation-only and the evidence uses fake HDC output plus
temporary Session storage. A maintainer must review this implementation and evidence in a PR before
the task state or any verification status has governance effect.

## Review-remediation addendum — 2026-07-18

This addendum addresses the safety and evidence findings received after the initial run. It does
not rewrite the historical command results above; it narrows the current conclusion to the checks
actually rerun after the remediation.

- The lifecycle executor now has a mandatory durable authorization/audit dependency. Immediately
  before a child launch it replays exactly one ordered durable preview → confirmation → typed intent
  tuple and rejects any mismatch; a missing tuple leaves the fake child invocation log absent.
  `kill` and `kill -r` do not have a registered success family, so they fail closed even after their
  argv has been durably recorded.
- Registered semantic success is now limited to the `uninstall` family and the exact pinned
  `success-uninstall` SHA-256 bytes. The evaluator streams a SHA-256 rather than retaining a
  second unbounded stdout copy. `checkserver` requires zero stderr, a pinned healthy byte family,
  and matching client/server versions; failure stderr is unavailable and version divergence becomes
  `mismatchUnverified`.
- The lifecycle adapter reconstructs the manifest confirmation tuple from replayed durable audit
  records after actor/store recreation, verifies ordered event linkage, and has a manifest-publication
  API that verifies the restored tuple before invoking the supplied `SessionManifestPublishing` seam.
- The production App starts with an explicit loading state and then uses `HDCReadOnlyDiagnosticsUseCase`,
  which reports a configured-candidate/endpoint state rather than rendering `.unprobed`. A
  `HDCServerDiagnosticsUseCase` supplies real supervisor state plus explicit impact-preview and
  confirmation requests; the UI has no executor or dispatch control. UI-test arguments are now a
  fixture provider behind the same view-model/use-case callback boundary, not the production source.
- Subserver evidence is now a fake-child invocation log from the real process supervisor:
  `checkserver` is the sole observed argv; neither `spawn-sub` nor `killall-sub` appears. The old
  detached lifecycle counter claim has been removed.

| Review command / check | Result |
| --- | --- |
| `swift format lint <changed TASK-M1-006 Swift files>` | pass, 0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests` | pass, 14 tests / 0 failures; current durable audit replay SHA-256 `c84166caf1b8beec34ddcbffeb0244f602802490c73c8ac3fb15a60fd57445f8` |
| `swift test --package-path Packages/ArkDeckKit` | pass, 185 tests / 1 existing skip / 0 failures; full-run durable audit replay SHA-256 `c1d67573e21de1fe467f1e671935783b0d1a067fa77b97e8dcf332877180970a` |
| `xcodebuild -quiet -project ArkDeck.xcodeproj -scheme ArkDeck -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/arkdeck-m1-006-ui-retry-lGAnU4 build-for-testing CODE_SIGNING_ALLOWED=NO` | pass; App and current UI-test target compiled |
| fresh `xcodebuild ... test` retries | not passed: one runner exited before bootstrap; one runner stalled in Xcode's local worker materialization and was interrupted after 124 s. Both runs built the targets; no test method began. |
| `env ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

Current conclusion: the review-remediated HDC contract evidence passes, but the changed macOS UI
suite has not produced a successful current run. `TASK-M1-006` therefore remains `ready`; do not use
the historical XCUITest rows as task closure until the local Xcode runner issue is resolved and the
complete suite, SDD check, and diff check are rerun.

## Review-remediation addendum 2 — 2026-07-18

This addendum addresses the subsequent lifecycle, ownership, App-composition, and manifest findings.
It supersedes the prior sentence that described `kill`/`kill -r` as necessarily failing because their
output is unregistered: registered command output is still not success evidence, but a confirmed
lifecycle operation can now complete when its post-dispatch observation proves the required state.

- `HDCProcessLifecycleExecutor` recognizes only exact `-s <selected-endpoint> kill` and
  `-s <selected-endpoint> kill -r` lifecycle argv families. It consumes the durable authorization by
  synchronously recording the exact actual argv before child launch; the durable adapter rejects any
  existing actual-command or outcome record. Thus retries and store-reopen recovery cannot launch the
  same step a second time. A restart succeeds only after exit zero, no stderr, and a re-probed changed
  generation; stop succeeds only after a re-probed unavailable endpoint. Other observations are
  `outcomeUnknown`.
- `arkDeckManaged` ownership now checks the live process table: positive live PID, resolved executable
  identity, complete argv (excluding argv[0]), and the exact `-s` endpoint. The contract test launches
  the local fake executable and rejects synthetic PID 910, wrong executable, and wrong endpoint before
  accepting the real process evidence.
- Normal App composition now uses `HDCApplicationDiagnosticsProvider`: it discovers explicit persisted
  user/DevEco/OpenHarmony paths at launch and is explicitly upgraded only by a Session-backed
  `HDCServerDiagnosticsUseCase`. The package contract test verifies configured discovery followed by
  durable-supervisor preview and confirmation presentation; the App still does not own executor or
  dispatch authority.
- Durable manifest confirmation reconstruction now retains and validates `decision=accepted`,
  `actor=user`, and the durable confirmation timestamp in addition to confirmation ID, scope hash, and
  related Step IDs. Publication rejects a rejected decision, wrong actor, or mismatched timestamp
  before it invokes the write-once publisher.

| Review command / check | Result |
| --- | --- |
| `swift format lint <changed TASK-M1-006 Swift files>` | pass, 0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests` | pass, 17 tests / 0 failures; includes durable single-use/reopen, confirmed-stop unavailable-probe, and App composition vectors |
| `swift test --package-path Packages/ArkDeckKit --filter HDCServerSupervisorContractTests.testTEST_AC_HDC_003_02_ManagedOwnershipRequiresAbsentEndpointAndVerifiedPidToolAndEndpointEvidence` | pass, 1 test / 0 failures; real local fake-process ownership vector |
| `swift test --package-path Packages/ArkDeckKit` | pass, 189 tests / 1 existing skip / 0 failures; current durable audit replay SHA-256 `af0fc844e98328b0ad9fee693d1b0d080cabafcd877f35401db6d3f41847937d` |
| `xcodebuild ... -derivedDataPath /private/tmp/arkdeck-m1-006-xcode.39TY9n build-for-testing CODE_SIGNING_ALLOWED=NO` | pass; App and HDC UI-test runner bundle compiled |
| `xcodebuild ... -derivedDataPath /private/tmp/arkdeck-m1-006-xcode.39TY9n test -only-testing:ArkDeckHDCUITests` | not passed: `xcodebuild` and `ArkDeckHDCUITests-Runner` remained without a test method/result for 85 s and were terminated as the test processes created by this run. This is a local runner stall, not a passing UI result. |
| `env ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

No command in this addendum executed an installed HDC, connected to a device, bound a network port,
or performed a destructive device action. The UI fixture remains test-only. Because a current macOS
XCUITest run still has no result, `TASK-M1-006` remains `ready` and this addendum does not assert task
completion, change verification, platform conformance, hardware evidence, or a release claim.

## Review-remediation addendum 3 — 2026-07-18

This addendum closes the final review findings with local, non-hardware evidence. It supersedes the
prior statement that current UI closure was unavailable. Task status remains `ready` pending human
review/merge; this is implementation evidence, not a verified change, platform-conformance result,
release claim, or real-device evidence.

- A dispatch lease is minted only after preview, confirmation, durable intent, and the post-intent
  Supervisor recheck. The executor atomically consumes that lease immediately before the only child
  launch. Any generation, affected-Job, ownership, endpoint, or critical-state transition invalidates
  outstanding leases. The fault vector pauses after durable authorization and then mutates generation,
  affected Job, and critical state in turn; all three conclude with the expired-lease failure and an
  instrumented lifecycle child-invocation count of `0`.
- `HDCClientVersionProcessProbe` executes only argv `[-v]` through `HDCProcessCommandRunner`, accepts
  the registered byte-exact `OPENHARMONY-TOOLS@0.2.0` version golden family, and otherwise returns
  unknown. `HDCServerProcessSupervisor` no longer accepts caller-provided generation or ownership:
  it derives external health observations through the Supervisor, which owns generation advancement;
  managed ownership remains available only through verified launch evidence.
- Normal App startup upgrades its read-only provider only after it composes a durable Session audit,
  manifest publisher, supervisor, and `HDCServerDiagnosticsUseCase`. The non-fixture UI vector passes
  `/usr/bin/true` as the explicit candidate: its safe `-v`/`checkserver` probes fail closed, then the
  visible recovery state proves the Session-backed supervisor is attached rather than the read-only
  provider. No installed `hdc` was invoked.
- The HDC UI-test target is locally signed (`CODE_SIGNING_ALLOWED=YES`, ad-hoc identity) in Debug and
  Release. The shared scheme ignores persistent saved state. The launch helper terminates a prior app,
  waits for a real window and HDC root, and reads the actual macOS accessibility `label`/`value`
  representation. Confirming an impact preview uses XCTest's built-in scroll-to-visible action and
  then asserts the resulting confirmation state.

| Final command / check | Result |
| --- | --- |
| `swift format lint <all changed TASK-M1-006 Swift files>` | pass, 0 diagnostics |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests` | pass, 19 tests / 0 failures; includes pinned `-v` probe, durable single-use/reopen, Session composition, and the dispatch-lease fault vector |
| `CI=true swift test --package-path Packages/ArkDeckKit` | pass, 191 tests / 0 failures / 1 existing skip; current TASK-M1-006 durable replay SHA-256 `7ac87d8968c1a8069c713a56fb8c060d0e8506a8b0b3e6505c47d4f01f50e9bf` |
| six `xcodebuild ... test -only-testing:ArkDeckHDCUITests/HDCStatusUITests/<exact method>` invocations, default signing, fresh explicit result bundles | each pass, 1 executed / 0 failed: diagnostics; key access; denied+timed-out authorization; authorized TCP/subserver; impact confirmation; normal Session-backed launch |
| `env ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

Xcode 26.6's local class/multiple-method `-only-testing` filter produced zero executed tests and an
incomplete result bundle; those zero-test exits are explicitly excluded from this conclusion. The six
fully qualified method runs above each have a readable xcresult summary with `totalTestCount=1`,
`passedTests=1`, and `failedTests=0`.

| Test ID | Binary conclusion | Current evidence |
| --- | --- | --- |
| `TEST-AC-HDC-001-01`, `TEST-AC-HDC-001-02` | pass | immutable snapshot; pinned process version probe; diagnostics UI fields |
| `TEST-AC-HDC-002-01` | pass | fake-child host-wide health/generation fan-out |
| `TEST-AC-HDC-003-01`, `TEST-AC-HDC-003-02` | pass | automatic lifecycle count `0`; verified live-process ownership evidence |
| `TEST-AC-HDC-004-01`, `TEST-AC-HDC-005-01` | pass | explicit child-only endpoint environment; registered byte-exact golden families |
| `TEST-AC-HDC-006-01`, `TEST-AC-HDC-007-01`, `TEST-AC-HDC-007-02` | pass | diagnostic key failure; bounded authorization; denied/timed-out UI |
| `TEST-AC-HDC-008-01`, `TEST-AC-HDC-009-01` | pass | TCP unverified warning; read-only subserver with spawn/killall instrumented `0` |
| `TEST-AC-HDC-010-01`, `TEST-AC-HDC-010-02`, `TEST-AC-HDC-010-03` | pass | critical UI gate; durable preview/confirmation/intent/actual/outcome reopen; three post-authorization lease invalidations with lifecycle count `0` |
| `TEST-MAC-M1-HDC-001` | pass | local fake-child process matrix; no device, network, or installed HDC claim |

Residual risk: real HDC/device behavior remains outside this Task and is not claimed. The App attaches
only after an explicit configured candidate; unavailable or unregistered probe output stays fail closed.

## Review-remediation addendum 4 — 2026-07-18

This addendum records the next review accurately. It supersedes any earlier
addendum wording that implied the dispatch lease and `posix_spawn` share an
atomic boundary. `TASK-M1-006` remains **ready** and the review remains
**request changes**: the evidence below proves only the in-scope fixes and
must not be used as a `done`, verified, platform-conformance, release, or
real-device claim.

### In-scope remediation completed

- `HDCServerProcessSupervisor` has no caller-provided diagnostic argv. Its
  only process request is `checkserver`; the fake-child environment seam varies
  fixture behavior without changing argv. The diagnostic-argv contract test
  records exactly `["checkserver"]`, with `kill`, `kill -r`, `spawn-sub`, and
  `killall-sub` invocation counts all `0`.
- A `checkserver` result now records generation evidence as explicit unknown.
  Two healthy observations cannot manufacture/reuse a lifecycle-eligible
  generation; preview is blocked as `impactCannotBeReliablyDetermined`.
- `HDCProcessCommandRunner` rehashes the selected candidate immediately before
  entering the process port. A fixture discovered at one hash and replaced at
  the same path is rejected with `toolchainIdentityChanged`; its child
  invocation log is absent. This is a pre-launch hardening only, **not** an
  inode/open-fd-to-spawn atomic identity guarantee.
- `HDCSessionDiagnosticsBootstrap.makeHost` is the sole API that creates a
  supervisor/durable lifecycle audit. `makeAttached(supervisor:...)` is the
  only additional Session composition route. Two Session recipients attached
  to the same endpoint receive the same single generation event.
- Unregistered `checkserver` mismatch bytes remain `unknown`; only zero-stderr
  registered pinned healthy bytes can be classified healthy. The raw mismatch
  fixture is no longer promoted to `mismatchUnverified`.
- XCUITest now asserts every fixture value exactly (toolchain fields,
  authorization variants, channel warning/subserver, and every impact-preview
  field), rather than merely asserting accessibility-element existence.

### Review items still open / not claimed

1. The final validation-to-`posix_spawn` race remains open. The current lease
   is consumed in HDC code before `FoundationProcessExecutor` reaches its
   internal spawn boundary; a Supervisor update after that consume cannot
   invalidate an already removed lease. Closing it requires a shared atomic
   launch gate spanning `ArkDeckOpenHarmony` and the forbidden
   `ArkDeckProcess` spawn implementation, plus the requested post-validation,
   pre-spawn fault hook. This task did not edit that forbidden path.
2. The hash recheck above still has a TOCTOU interval before spawn. Executing a
   verified open descriptor/inode or moving the recheck into the process launch
   gate is part of the same out-of-scope Process change.
3. Authorization has only the existing maximum-attempt closure test. There is
   no registered read-only authorization command family from which to build a
   production process probe, deadline/cancellation vector, or an identity
   match. Binding identity/revision is explicitly TASK-M1-007 scope. The
   previous `AC-HDC-007-*` passing conclusion therefore does not close this
   review finding.
4. Key access and subserver capability remain presentation/fixture state. The
   current integration profile has no registered read-only platform probe for
   either; inventing one would alter the profile/fixture registry, both
   forbidden here. The previous `AC-HDC-006-01` and `AC-HDC-009-01` conclusions
   do not establish production platform-probe closure.
5. The sandboxed App still persists absolute paths, not security-scoped
   bookmarks. No user-selection/bookmark lifecycle or allowed entitlement
   change is present in this task. The `/usr/bin/true` UI test does not prove
   access to a user-selected SDK executable after restart.

### Reverification

Base revision: `e29462cda1950a2adfc986d682fe6a158ccf3ae3` (dirty TASK-M1-006
worktree); Swift `6.3.3`; Xcode `26.6 (17F113)`; read-only Golden registry
SHA-256 `b62436ced0cfbb300320a126fed3a182da036e2b72a964ea265a20a8fbdde25a`.
No command executed installed `hdc`, contacted a device, bound a network port,
or performed a destructive operation.

| Command / evidence | Result |
| --- | --- |
| `swift format lint <changed TASK-M1-006 Swift files>` | pass, 0 diagnostics |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests` | pass, 23 tests / 0 failures; includes closed diagnostic argv, same-path replacement, unidentified-generation, shared-Supervisor Session fan-out |
| `CI=true swift test --package-path Packages/ArkDeckKit` | pass, 195 tests / 1 existing skip / 0 failures |
| `xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/arkdeck-m1-006-xcodebuild.Ynjw0F/DerivedData -resultBundlePath /private/tmp/arkdeck-m1-006-xcodebuild.Ynjw0F/ArkDeck.xcresult test` | pass, no signing override; fresh result summary reports 7 total / 7 passed / 0 failed / 0 skipped |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

The full Xcode result bundle is local-only at
`/private/tmp/arkdeck-m1-006-xcodebuild.Ynjw0F/ArkDeck.xcresult`; its
`xcresulttool` summary reports `result=Passed`, `totalTestCount=7`,
`passedTests=7`, and `failedTests=0` on macOS arm64. This closes the prior
whole-suite UI-evidence gap only; it does not close any of the five open safety
or platform findings above.

## Review-remediation addendum 5 — 2026-07-18

This addendum addresses the newly identified public HDC execution surface.
It does not change the task status: **TASK-M1-006 remains `ready` / request
changes**. The unresolved findings listed below remain blockers and this is
not completion, verification, platform-conformance, release, or hardware
evidence.

### Closed in this addendum

- `HDCProcessCommand`, `HDCProcessCommandRunner`, and
  `HDCProcessLifecycleExecutor` are module-internal implementation types.
  External consumers cannot construct an arbitrary HDC `arguments` array,
  invoke the runner, or construct the process lifecycle executor with a fake
  audit/lease dependency. The publicly callable production probe types expose
  only their fixed registered argv: `HDCClientVersionProcessProbe` emits
  `[-v]`; `HDCServerProcessSupervisor` emits `[checkserver]`.
- The fake-child matrix now imports `ArkDeckOpenHarmony` with `@testable`; its
  arbitrary argv is an internal test seam, not a package/App public API. The
  production App target compiled and the complete UI suite passed after this
  visibility change.
- Source-surface review confirms no `public` declaration remains for the
  command, runner, or process lifecycle executor. Existing diagnostic argv
  instrumentation still records exactly `checkserver` and zero lifecycle or
  subserver mutation argv.

### Still open / explicitly not claimed

1. Dispatch lease finality still precedes `posix_spawn`; an update in the
   post-consume/pre-spawn interval can race the child launch. A shared launch
   gate and fault hook require the forbidden `ArkDeckProcess` path.
2. Toolchain SHA revalidation remains pathname TOCTOU until the verified
   inode/open descriptor is bound to the Process launch boundary.
3. `checkserver` deliberately establishes unknown generation and unreliable
   impact state. With no approved production identity/generation probe, an
   external server correctly remains blocked from preview/confirmation. Thus
   the existing direct-known-generation lifecycle tests do not close a normal
   App `AC-HDC-010-02` path.
4. Authorization polling has no per-probe/overall deadline guarantee for an
   uncooperative probe, no registered production authorization command, and
   no TASK-M1-007 binding-identity/revision recheck.
5. `HDCJobToolchainSnapshot` remains an in-memory diagnostics value; writing
   it to the actual Core Job intent and durable reopen seam needs forbidden
   Core/storage/workflow paths. Its value-semantics test is not persistence
   evidence.
6. The sandboxed App still persists absolute paths rather than a
   security-scoped bookmark lifecycle.
7. Key access and subserver capability remain fixture/presentation state: the
   integration profile does not register a read-only production probe for
   either, so their platform ACs are not closed.

| Command / evidence | Result |
| --- | --- |
| `swift format lint <changed TASK-M1-006 Swift files>` | pass, 0 diagnostics |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests` | pass, 23 tests / 0 failures after public-surface closure |
| `CI=true swift test --package-path Packages/ArkDeckKit` | pass, 195 tests / 1 existing skip / 0 failures |
| `rg` public-surface review for `HDCProcessCommand`, `HDCProcessCommandRunner`, `HDCProcessLifecycleExecutor` | pass: zero public declarations; only module-internal implementation references remain |
| `xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/arkdeck-m1-006-xcodebuild-public-api.41JhOl/DerivedData -resultBundlePath /private/tmp/arkdeck-m1-006-xcodebuild-public-api.41JhOl/ArkDeck.xcresult test` | pass, default signing/no override; xcresult reports 7 total / 7 passed / 0 failed / 0 skipped |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

No command in this addendum executed an installed HDC, contacted a device,
bound a network port, or performed a destructive action.

## Review-remediation addendum 9 — 2026-07-18

This addendum records the latest in-scope remediation and final local
reverification. `TASK-M1-006` remains **ready / request changes**. It is not a
`done`, change-verification, platform-conformance, release, real-HDC, or
hardware claim.

### Closed or materially remediated in this addendum

- Every endpoint-sensitive `checkserver` probe now preserves an explicit
  endpoint as the fixed registered argv `[-s, <endpoint>, checkserver]`.
  Inherited/default selection remains the registered bare `checkserver` form.
  The fake-child invocation log proves that a non-loopback hostname is not
  silently converted into a local same-port observation.
- Managed ownership is now gated by the live PID, resolved executable, complete
  argv, declared endpoint, and a TCP `LISTEN` socket owned by that same PID at
  the selected local endpoint. The production inspector and managed-start
  authorization/evidence surfaces are module-internal. A repository fake
  process on an ephemeral loopback port proves that a made-up PID, wrong
  executable, wrong endpoint, or absent listener is rejected. Accepted
  ownership deliberately records generation/version certainty as unknown, so
  caller-supplied fields do not mint lifecycle authority.
- A terminal lifecycle reconciliation now persists the complete typed observed
  scope: action, endpoint, health/version, generation and its evidence,
  ownership, affected coordinators/Jobs, other-client detection, critical
  Jobs, impact reliability, and scope hash. Every historical `succeeded` or
  `stopped` outcome requires that terminal record, including an unchanged
  scope. Reopen without it resolves to `outcomeUnknown`; an injected
  reconciliation append failure cannot escape as success.
- Final manifest publication now validates the complete correlated durable
  chain: preview, accepted user confirmation, intent, exact typed lifecycle
  argv, outcome, and terminal reconciliation. Rejected/wrong-actor
  confirmations, missing actual-command/outcome/reconciliation records, or a
  mismatched scope/outcome block publication.
- The authorization probe/workflow/policy construction surface is
  module-internal. This prevents an importing App/module from presenting an
  arbitrary closure as production authorization evidence; it does not claim a
  process-backed authorization probe exists.

### Findings still open / intentionally fail closed

1. The App still has no production composition from Core's registered
   `mutateHDCServerLifecycle` `WorkflowStep` through the internal durable HDC
   executor. Preview/confirmation is therefore not a production mutation
   closure. Closing this needs an approved cross-module authority design; a
   public executor/factory would reopen the forged-success path.
2. Dispatch-lease consumption and pathname hash revalidation still occur
   before `FoundationProcessExecutor` reaches `posix_spawn`. A Supervisor
   update or pathname replacement in that interval cannot be made atomic in
   the task-allowed HDC paths. The shared final launch gate, fault hook, and
   descriptor/inode-bound execution require the forbidden `ArkDeckProcess`
   implementation and a separate approved change.
3. The registered production server probe remains `checkserver`, which cannot
   establish process/server identity or generation, and there is no production
   post-dispatch generation probe. External-server impact preview correctly
   remains blocked until an approved integration profile registers such an
   identity family.
4. Authorization still has no registered process-backed probe or
   selected-device identity/binding revision recheck. The timeout race returns
   to its caller, but an implementation that ignores cancellation may retain
   its own external resources; production resource ownership and binding
   revalidation need their registered adapter/TASK-M1-007 scope.
5. `HDCJobToolchainSnapshot` remains diagnostics memory rather than a Core Job
   intent persisted through Session reopen, and the lifecycle manifest adapter
   still has no production finalization caller. The required Core/Storage and
   wider workflow paths are forbidden to this task.
6. Key-access and subserver capability remain fixture/presentation states
   because no legal production read-only families are registered. The
   security-scoped bookmark code and contract test exist, but a signed sandbox
   App file-picker selection of an external SDK followed by App relaunch has
   not been executed end to end.

### Reverification and deviation

No command executed the installed real `hdc`, contacted a device, reached a
non-loopback network endpoint, or dispatched a lifecycle/destructive command.
The managed-ownership test launched only the repository fake process and bound
one ephemeral loopback listener, which it then stopped.

| Command / check | Result |
| --- | --- |
| `swift format lint --strict <changed TASK-M1-006 Swift files>` | pass, 0 diagnostics |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDC` | pass, 55 tests / 0 failures |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCServerSupervisorContractTests` | pass, 18 tests / 0 failures |
| `CI=true swift test --package-path Packages/ArkDeckKit` | pass, 208 tests / 1 existing manual sleep/wake skip / 0 failures |
| targeted source-surface review | no public lifecycle executor/dispatch/lease, managed-start authorizer/evidence/inspector, or authorization workflow/policy declaration |
| first default-signing `xcodebuild test` (`/private/tmp/arkdeck-m1-006-review9.4vYEVH/ArkDeck.xcresult`) | exit 65; runner signed as `Sign to Run Locally`, then timed out enabling XCTest automation mode before any test method |
| clean DerivedData/result-bundle default-signing rerun (`/private/tmp/arkdeck-m1-006-review9-rerun.oVQJgH/ArkDeck.xcresult`) | exit 65; same pre-test automation-mode timeout; `xcresulttool` reports 0 passed and one runner-initialization failure |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

The two XCUITest attempts demonstrate that the project no longer disables
runner signing, but they do **not** establish UI closure for this revision.
The repeatable failure is retained as an environment/test-initialization
deviation rather than being converted into an assertion pass.

## Review-remediation addendum 6 — 2026-07-18

This addendum records the latest review against the actual module boundary.
`TASK-M1-006` remains **ready / request changes**. It closes only the two
public API forgery routes below; it is not completion, verification,
platform-conformance, release, or hardware evidence.

### Closed public API forgery routes

- `HDCServerLifecycleExecutor`, `HDCServerLifecycleDispatchLease`,
  `HDCServerLifecycleDispatchLeaseValidating`, the Supervisor's
  `dispatch(confirmationID:using:)`, and `consumeDispatchLease` are now
  module-internal. An App or any other importing module cannot implement an
  executor that returns a forged success, mint a lease, consume a lease, or
  call Supervisor dispatch while bypassing durable actual-command audit.
  The only process lifecycle executor remains the module-internal
  `HDCProcessLifecycleExecutor`, which writes durable actual argv and consumes
  the Supervisor lease before it enters the HDC process runner.
- `HDCServerState` no longer has a public initializer; raw
  `HDCExistingServerObservation`, `observeExistingServer`,
  `observeUnidentifiedExternalServer`, and `setImpactReliability` are also
  module-internal. External callers can inspect `state(for:)` but cannot mint
  known generation evidence or inject a reliable-impact observation. The
  remaining public managed-start route validates PID, executable path, argv,
  and endpoint through the live process inspector before it records managed
  ownership.
- Existing supervisor fakes now compile solely via `@testable import
  ArkDeckOpenHarmony`. They remain contract-test fixtures for Supervisor state
  transitions and are not available to an importing production module. The
  App target compiled against the narrowed public API; it continues to expose
  diagnostics/confirmation only, rather than a raw lifecycle executor.

### Findings still open / intentionally fail closed

1. A post-lease-consume/pre-`posix_spawn` race remains: the current Supervisor
   cannot revoke a lease already removed by `consumeDispatchLease`. A shared
   atomic launch gate and fault hook require the forbidden `ArkDeckProcess`
   spawn implementation.
2. Candidate hash revalidation remains pathname TOCTOU until a verified
   descriptor/inode is bound to the Process launch operation; that belongs to
   the same forbidden Process change.
3. The public generation-forgery route is closed, but production
   `checkserver` still deliberately establishes unknown generation and
   unreliable impact. No approved identity/generation probe exists, so a real
   external server remains blocked from preview/confirmation rather than
   treating fixture-known generations as App closure evidence.
4. Authorization has no registered process-backed probe, per-probe/overall
   deadline for an uncooperative probe, or TASK-M1-007 binding identity/revision
   recheck. Job toolchain snapshot persistence, security-scoped bookmarks,
   platform key-access diagnostics, and subserver-capability probing likewise
   need their respective forbidden Core/Storage, entitlements, or integration
   profile scope. Their fixture/UI checks are not claimed as production AC
   closure.

### Reverification

No installed `hdc`, device, external network endpoint, or destructive server
operation was used. The fake-child suite alone exercised child processes.

| Command / check | Result |
| --- | --- |
| `swift format lint <changed TASK-M1-006 Swift files>` | pass, 0 diagnostics |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests` | pass, 23 tests / 0 failures |
| `CI=true swift test --package-path Packages/ArkDeckKit` | pass, 195 tests / 1 existing skip / 0 failures |
| targeted source-surface review | no public lifecycle executor, dispatch, lease, lease validator, raw observation, or state initializer declaration remains |
| `xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/arkdeck-m1-006-xcodebuild-review6/DerivedData -resultBundlePath /private/tmp/arkdeck-m1-006-xcodebuild-review6/ArkDeck.xcresult test` | pass, default signing/no override; `xcresulttool` reports 7 total / 7 passed / 0 failed / 0 skipped |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-python/bin/python scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |
