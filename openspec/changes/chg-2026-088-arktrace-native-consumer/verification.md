# Verification — CHG-2026-088

> Change:CHG-2026-088-arktrace-native-consumer@r1

## Local targeted checks — 2026-10-29

The original ArkDeck workspace was synchronized to main and the unpublished
native consumer increment was adapted to the current `apple/` and `hack/`
layout. Necessary upstream APIs and fixed product packaging are in ArkTrace
PR #68, merged as `1d0e02fbe571fe5af6a99b6fe2b3c764fc488400`. This section supersedes the local-only source pins in the retained
historical records below.

On macOS arm64, Xcode 27.1 / Swift 6.4 and Rust 1.99.0:

- Default graph: configuration/bootstrap, architecture and auto-update contract
  tests pass (39 tests, exit 0).
  Log: `/private/tmp/arkdeck-main-sync-20261029/arkdeck-swift-default.log`.
- Explicit normal ABI-2 SDK graph: native product configuration, product
  identity and bootstrap startup/Quit tests pass (10 tests, exit 0).
  Logs: `/private/tmp/arkdeck-main-sync-20261029/arkdeck-swift-native.log`
  and `arkdeck-native-final-pin.log` (the shared CI entry on the published pin).
  The final pin also passed 7 architecture and 23 auto-update tests, exit 0;
  log: `arkdeck-final-pin-contracts.log`.
- `sh hack/ci/run-xcodebuild.sh`: unsigned Debug build-for-testing succeeds
  (exit 0). It links the explicit normal SDK and copies the same admitted
  tools/manifests without re-signing or rewriting them. Both legacy helper
  phases were removed; the current sandbox input list declares all native
  inputs. This is compilation, not signed native App startup acceptance.
  Log: `/private/tmp/arkdeck-main-sync-20261029/arkdeck-app-build.log`.
- Build/UI runner and packaging tests: 44 tests, exit 0. SwiftPM runner tests:
  14 tests, exit 0. Source preparation tests: 5 tests, exit 0.
  Logs: `runner-resource-tests.log`, `swift-runner-tests.log`, and
  `native-prep-tests.log` in the same temporary evidence directory.
- Release builder: 40 sandbox-compatible tests passed; the real hdiutil test
  initially failed under the filesystem sandbox and passed when rerun with
  host access (exit 0). Logs: `release-tests.log`, `release-hdiutil-test.log`.
- One Viewer UI case was attempted through `run-ui-tests.sh`, then retried
  once without rebuilding as the acceptance guide permits. Both attempts
  timed out while enabling Xcode automation mode before any UI assertions.
  UI presentation is therefore unverified. Logs: `arkdeck-viewer-ui-first.log`
  and `arkdeck-viewer-ui-retry.log`; no system automation settings were changed.
- Trace facade contracts: 12 tests, exit 0. Log: `trace-facade-contracts.log`.
- Planner tests: 61 tests, exit 0. Log: `planner-tests.log`.
- Design interaction tests: 86 tests, exit 0. The new and old upstream
  shortcut catalogs are byte-identical; only the prototype reference pin
  and migrated source path changed. Log: `design-interactions.log`.
- SDD validation: exit 0. Log: `arkdeck-sdd.log` in the same directory.

Native SDK preparation runs before App, UI-test and release builds. Release
preparation requires signed, runtime-usable tools and fails before archiving
when unavailable. The SwiftPM runner can stage the same verified SDK under
its existing lock; CI exercises the portable graph and native adapter tests.

Capture forms remain available during Viewer startup. Empty Viewer UI tests
use an explicit Debug-only fixture; production startup still fails closed
without admitted tools. The native writer namespace stays separate from the
existing schema-3 daemon cache. The daemon analyzer distribution, schema-4
Artifact lineage, cross-process purge compatibility and signed native GUI
startup/open/close remain outside this increment's verified scope.

Existing BigInt watchOS manifest and StrictMemorySafety diagnostics remain;
this is not a zero-warning claim. No device execution or live cache change
was performed. No full local unified gate was run; selected full lanes belong
to PR CI.

## CI

ArkTrace #68 merged after its full PR CI run 40882774322 passed, including
`CI required`, SwiftPM, offline gates, macOS SDK and Windows checks.
ArkDeck #2718 first failed Swift CI run 40884657679 in the design prototype
shortcut pin assertion, before compilation. The unchanged shortcut catalog
was verified against both source revisions and its mirror reference refreshed.
Run 40885074528 then reached native preparation and exposed missing
`rustfmt` in the minimal Rust toolchain. App, UI and release setup now
install that exact component because SDK binding verification invokes it.
Run 40885874251 exposed the upstream cache-owner registration requirement.
The common native preparation entry now registers explicitly configured
owner/cache pairs against the pinned checkout before building, preserving
restored products and refusing mismatched owner/source bindings. An actual
temporary-cache registration replay verified idempotence and retained bytes
and inode; the source preparation suite passes five tests.
Run 40886736757 passed App build-for-testing, then found an obsolete
Swift source assertion requiring the capture form to call a document
controller directly. The contract now verifies the injected open callback
and its composition through the shared Trace Runtime.
Final CI run IDs are recorded in the PR delivery description. CI uses
Xcode 27.0, separately from the local 27.1 build.

## Retained historical evidence

The following records describe the original local increment and its older
source/SDK pairs. They do not establish validation of the current PR.

## Local targeted checks — 2026-10-06

The default dependency graph passed 33 related tests; the normal native SDK
graph passed 35 (configuration, architecture boundary and auto-update contract
classes). SDD passed. Existing BigInt 5.7.0 manifest diagnostics deprecate its
watchOS v4 declaration; these are dependency-manifest warnings, not a change to
ArkDeck's macOS baseline or a zero-warning CI result.

The dependency checkout has clean tracked source at
`17278f7f02c3ff0902f30af09db621f56caba0cb`, with only the explicitly verified
`.arktrace-native/` SDK staging directory untracked. The source commit remains
local pending direct push approval. A session-only SwiftPM mirror points to the
local Git repository; it does not change remote refs or establish public
resolvability. No mirror configuration is committed to ArkDeck.

An independently compiled consumer used the actual adapter and the normal
SDK library `63365301a6b12c06b25e06a8f55c2e823b8f38abc2a395e004b51e91ee390691`.
With copied, Developer-ID signed tools using ArkDeck's fixed identifiers, it
cold-opened the 67,837-byte bundled fixture, obtained a snapshot, closed,
reopened with cacheHit, closed again and joined shutdown. Public maintenance
reported active entries 1 during open and 0 after close. Source SHA-256 remained
`eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe`.
It used an independent cache and preference domain. This proves the local SDK
composition/lifecycle only; it is not the sandboxed ArkDeck App or an actual
Runtime Artifact chain. Complete process-forest, resource-peak and compiler-input
closure proofs are not claimed.

Evidence is retained in the ArkTrace workspace's
`build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/arkdeck-native-sdk-adapter-20261006/`,
including the original startup rejection and the source URL compatibility fix.

## Historical CI status — 2026-10-06

Not executed. No ArkDeck commit, push, PR or maintainer approval is claimed.

## Local targeted checks — 2026-10-07

At that time, the source pin was `643bde8fe06d1adafe5a94a0831fafa4d5b3d40b`.
The normal SDK library remains
`4e0dcedf252e0e5c0212d5edb8b6187f1e640f7ba037bcea6ec3d5a4c296389f`
with ABI 2 and the matching generated contract/headers. The current default
graph passes 7 architecture XCTest cases and 8 Swift Testing cases, including
missing-SDK startup failure and the four startup/Quit lifecycle regressions.

`run-xcodebuild.sh` passes unsigned Debug build-for-testing. Its actual compile
links this SDK and defines the native adapter graph. The final four bundled
resources equal the admitted fixed ArkDeck input artifact. Both tools'
Developer ID, runtime flag and complete two-key inheritance DER payloads were
read back successfully. The full signed input receipt, two binaries, two
manifests and the unsigned 66-file App are preserved in the owning ArkTrace
evidence directory, rather than depending on a temporary cache. The App's
outer signature and actual startup/GUI remain unverified.

The first two preparation failures are retained: a registered Cargo owner could
not switch its source root to the resolved checkout, then SDK staging could not
distinguish the checkout from the consuming repository. The final runner reuses
verified immutable inputs locally, binds staging outside the physical consuming
Git repository and keeps the same Cargo owner/cache. Its 43 source, packaging,
runner and keyboard-lifecycle contract tests pass; SDD passes.

The current native configuration/pin group passes 35 cases: 7 architecture
XCTest cases, 5 Swift Testing configuration cases and 23 auto-update cases.
The four lifecycle cases also passed in the prior native wiring group; no
fresh native engine cancellation result is implied.

Warning audit: the earlier pin checks reported BigInt 5.7.0's existing watchOS-v4
manifest deprecation. The current clean default graph reports an existing
`PortableCanonicalJSON.swift` StrictMemorySafety site. App build reports that
StrictMemorySafety site, one signed-parser stripping warning, and two optional
AppIntents metadata warnings. This is not a zero-warning result.

The current private development Rust CLI candidate successfully executes
`inspect` on a task-owned read-only fixture and reports index schema 4. Its
actual `doctor --self-test`, `summary` and `analyze` invocations return
`INVALID_ARGUMENT`: these commands are not wired yet. This ad-hoc development
candidate is not the reviewed CLI distribution and cannot replace the daemon's
existing schema-3 profile or prove an Artifact chain/maintenance lease.

Evidence subdirectories: `57-arkdeck-app-startup`,
`58-fixed-product-app-inputs`, `59-current-schema4-cli-baseline`, and
`60-current-arkdeck-app-candidate`. Original failed logs and clocks remain
unchanged. Current source pins are still local; CI, publication and maintainer
approval are not claimed.
