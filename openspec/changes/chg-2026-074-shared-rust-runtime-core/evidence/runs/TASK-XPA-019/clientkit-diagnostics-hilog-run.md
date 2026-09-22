# Diagnostics Hilog reader in ClientKit

Base: protected main `37453467d`. Independent of Viewer PR #2109. TASK-XPA-019
remains incomplete; this is a production read-path slice, not deployment or
real-device acceptance.

## Delivered behavior

The Diagnostics App view previously needed Workflows because
DiagnosticHilogSummaryReader directly used the analyzer provider's integrity
validator. The reader now belongs to ClientKit. Core owns the existing
HilogSummaryAnalysis and HilogSummaryDerivedArtifact package models and the one
canonical report validator. Workflows' analyzer and the ClientKit reader both
consume that implementation; profile selection, subprocess execution, raw log
analysis and Runtime authority remain in Workflows.

All model fields, report bytes, analyzer/version pins, input/output budgets,
closed canonical JSON checks, source digest/size matching, histogram invariants
and coverage rules are preserved. Package-only initializers allow the existing
producer to construct the moved models without exposing a new public API.
Reader error codes, correlated Job/target/Session requirements, standard-only
16 KiB artifact reads, output hash and source-lease checks are unchanged.

App production composition already injects RuntimeJobDetailApplicationFacade;
Diagnostics now consumes its current job.show, job.timeline, job.evidence,
artifact.list and artifact.read resources entirely through ClientKit. Those
read methods exist on the standalone Rust History Mach ingress. No new control
method, Package.swift dependency, fallback, wire/schema change or device dispatch
is introduced. No installed Runtime/LaunchAgent is touched.

The monitor assigned these Swift Core/Workflows/ClientKit shared files to this
App task. The Runtime task owns Rust App ingress admission and backend methods.

## Local targeted checks

- `ARKDECK_SWIFTPM_CACHE_ROOT=/private/tmp/arkdeck-e190-swift sh
  Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --jobs 2 --filter
  'DiagnosticHilogSummaryReaderContractTests|DiagnosticSessionReadingContractTests|AnalyzerProviderContractTests'`:
  exit 0, 50 tests passed (5 ClientKit reader, 25 Session reader, 20 analyzer);
  `/private/tmp/arkdeck-e190-diagnostics-tests.log`.
- `sh scripts/check-sdd.sh`: exit 0, zero errors/warnings;
  `/private/tmp/arkdeck-e190-diagnostics-sdd.log`.
- `ARKDECK_XCODE_CACHE_ROOT=/private/tmp/arkdeck-e190-xcode ARKDECK_XCODE_JOBS=2
  sh scripts/ci/run-xcodebuild.sh`: exit 0, TEST BUILD SUCCEEDED;
  `/private/tmp/arkdeck-e190-diagnostics-app-build.log`.

The reader's four existing contract tests move into the ClientKit test target;
a read-failure case verifies unavailable output without retry. Provider/reader canonical equivalence remains covered by the existing
producer test rather than a second validator implementation.

Independent state: /private/tmp/arkdeck-e190-swift and
/private/tmp/arkdeck-e190-xcode. No full local gate, performance measurement,
signed Rust Mach execution, UI interaction or real-device claim.

## CI

Pending this slice's PR. Previous Viewer PR #2109 head c0a10de1 passed guard
35705967006 and Swift CI 35705967408 (swift-tests, app-build, ds-tokens,
ds-interactions, required swift aggregate). Rust was unselected/skipped. Those
results do not validate this independent diff; fresh CI and maintainer review
are required here.
