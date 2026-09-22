# Remaining App Job consumers use current resources

Base: protected main `86434afd8`, including Rust App-owned Job ingress #2113
and signed-host harness #2114. TASK-XPA-019 remains incomplete.

## Production behavior

Device historical screenshots, History cancellation and workspace continuation
now read `job.show` (and `job.timeline` when paged), not retired `job.status`.
They share ClientKit's bounded current resource validation. Existing Job, target,
operation, Session, state, unknown, waiting and residue checks are preserved.
Unconfirmed screenshot history never reads artifacts; confirmed history still
uses owner/digest/range-validated artifact resources and never submits a Job.
Cancellation remains an accepted request to Runtime, not a terminal assertion.

Continuation consumes a compact `job.run` acknowledgment, then reads the current
Job resource before publishing a state. It removes its one-shot local accepted
handle before dispatch, so an unknown or disconnected read cannot cause replay.
It still submits a new request/idempotency identity after fresh source and target
checks; no old Runtime authority, Session or reservation is copied.

The Overview window-inventory runner now lives beside ClientKit's existing Debug
submission/execution implementation. App production assembly and the existing
Runtime integration contract consume the moved implementation, not a duplicate.
The existing provider wire-value and succeeded/failed/malformed terminal tests
remain. Debug and Trace already used the current Job resources; those previously
migrated paths are not reimplemented.

The Rust #2113 closed-client gate does not yet accept the existing continuation
clientName `arkdeck-overview-continuation` (observe.device@1/capture.diagnostics@1).
That exact interface need was sent to the Runtime owner and monitor. The client
identity is not changed to impersonate another workspace, and no backend gate
or shared contract is modified here. A rejection remains unconfirmed and cannot
be run. This slice does not claim a completed Rust continuation loop.

## Local targeted checks

- `ARKDECK_SWIFTPM_CACHE_ROOT=/private/tmp/arkdeck-e190-swift sh
  Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --jobs 2 --filter
  'RuntimeHistoryApplicationContractTests|OverviewRunRecordContractTests|DeviceProductionProviderContractTests|DebugWindowInventoryJobRunnerContractTests'`:
  exit 0, 65 passed (60 ClientKit + 5 existing Runtime integration contracts);
  `/private/tmp/arkdeck-e190-app-job-reads-final-tests.log`.
- `ARKDECK_XCODE_CACHE_ROOT=/private/tmp/arkdeck-e190-xcode ARKDECK_XCODE_JOBS=2
  sh scripts/ci/run-xcodebuild.sh`: exit 0, TEST BUILD SUCCEEDED;
  `/private/tmp/arkdeck-e190-app-job-reads-build.log`.
- Added failure coverage: continuation disconnect after a successful compact
  acknowledgment does not run twice; cancellation read failure dispatches no
  cancel; foreign/unknown/waiting/residue historical screenshots read no bytes.
  Successful historical screenshot reads current detail plus verified artifacts.

No full local gate or repeated UI sweep: no view layout/interaction changed.
These in-process fixtures and existing Swift Runtime tests do not constitute
signed standalone Rust Mach, real hardware or recovery acceptance. The independent
login/VM requirement from the host-harness evidence is still outstanding.

## CI

Pending this slice's PR, required guard/swift checks and maintainer review.
