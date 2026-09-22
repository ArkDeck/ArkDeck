# ClientKit Viewer and current Job projections

Base: protected main `37453467d` (#2105). CHG-2026-074 / TASK-XPA-019 remains
incomplete. This slice migrates the production Viewer provider and fixes its
current-protocol Job reads; it does not establish signed App-to-Rust acceptance.

## Product behavior

UIDumpApplicationFacade, its offline inspector, capture metrics and opt-in UI
fixture now belong to ArkDeckClientKit. The App's Viewer source no longer imports Workflows. Diagnostics still needs
DiagnosticHilogSummaryReader and its Workflows-owned artifact validator. Production composition still calls
UIDumpApplicationFacade.make(), whose default sender uses the shared authenticated
RuntimeXPCRequestTransport. No fixture fallback, Swift forwarding, transport
identity change, local device execution or admission logic is introduced.

Capture and advanced dump submit a typed capture.diagnostics@1 request, await
job.run, then read the current job.show projection (including bounded paged
timeline support). The compact run acknowledgement is not treated as complete
terminal evidence. Historical Viewer reopening reads job.show directly, without
job.status, submission or dispatch. Unknown outcomes, waiting-for-human state,
residue and mismatched Job/target/operation identities refuse rendering. Timeout
and disconnection do not replay the request. Artifact owner, size, digest and
bounded range validation remain in the production path.

## Exact IPC methods and remaining backend dependency

- Workspace: operation.list, target.list, job.list; consumes the shared device
  observation instead of probing again.
- Capture / advanced dump: job.submit, job.run, job.show, optional job.timeline,
  artifact.list, artifact.read. Cancellation: job.cancel.
- History reopening: job.show, optional job.timeline, artifact.list, artifact.read.
- Diagnostics remains outside this slice: App compilation verified its real
  dependency on the Workflows Hilog summary reader/validator. Its import is kept.

At this base, Rust HistoryIngress admits health, history.filter.*, job.list,
job.show, job.timeline, job.evidence, artifact.list and artifact.read. It refuses
operation.list, target.list, job.submit/run/cancel and device.observations.
Consequently the Viewer history read methods are available at the Rust Mach
boundary, but capture and fresh target selection cannot yet complete there.
The monitor assigned app_ingress.rs and typed App job/import ownership to the
Runtime task; this task consumes that interface and does not duplicate it.

The production fixed Mach service still requires the pinned daemon signature and
current contract handshake. No installed LaunchAgent or Runtime was changed.
A safe isolated signed App/Mach execution environment and real-device acceptance
remain outstanding; in-process wire fixtures are not those proofs.

## Local targeted checks

- `ARKDECK_SWIFTPM_CACHE_ROOT=/private/tmp/arkdeck-e190-swift sh
  Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --jobs 2 --filter
  'UIDump|ViewerRealDumpShapeTests|RuntimeXPCRequestTransportTests|CLIOfflineDerivationContractTests'`:
  exit 0, 47 tests passed (29 ClientKit, 18 contract tests); log
  `/private/tmp/arkdeck-e190-viewer-final-tests.log`.
- The five new production-provider tests cover verified advanced-dump artifact
  publication, compact run followed by current detail, unknown outcome refusal,
  cross-target historical refusal, timeout without replay and disconnected
  detail without artifact reads. Existing parser/offline/transport tests pass.
- `sh scripts/check-sdd.sh`: exit 0, zero errors/warnings;
  `/private/tmp/arkdeck-e190-viewer-sdd.log`.
- `ARKDECK_XCODE_CACHE_ROOT=/private/tmp/arkdeck-e190-xcode ARKDECK_XCODE_JOBS=2
  sh scripts/ci/run-xcodebuild.sh`: exit 0, TEST BUILD SUCCEEDED;
  `/private/tmp/arkdeck-e190-viewer-app-build.log`. An initial attempt caught
  the unmigrated Diagnostics Hilog reader; retaining its import fixed that
  scope error. App import count is seven, not a completion claim.
- Viewer UI execution and signed Rust Mach integration are not included in
  these contract checks. No performance threshold was measured or changed.

Compilation caught missing ClientKit imports in the retained Swift CLI offline
exporter and old test consumers; those imports were corrected, including
@testable access for internal test fixtures. The new success fixture initially
used standard privacy; it was corrected to the published sensitive dump
metadata without relaxing production validation.
Build state is isolated under /private/tmp/arkdeck-e190-swift and
/private/tmp/arkdeck-e190-xcode. The initial sandbox invocation could not write
the compiler module cache; it was retried with controlled host permissions.

## CI

Pending PR submission. Required guard/swift results must be read from the PR;
no local full gate or fixture result substitutes for CI or maintainer review.
