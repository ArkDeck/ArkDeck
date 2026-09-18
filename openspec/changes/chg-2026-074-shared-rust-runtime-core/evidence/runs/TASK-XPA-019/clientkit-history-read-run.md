# ClientKit History read and client JobControl extraction

Date: 2026-09-19. Stacked base: PR #1976, commit
`b710252d1d7844f1fcd361e58c66429a06173493`. This slice depends on that PR's
ClientKit target/transport; it does not presume the PR has merged.

## Production change

- Move the complete History summary/detail reader, Artifact preview/export,
  presentation models, workspace-kind display projection, and client JobControl
  facade from Workflows into ClientKit. ClientKit still depends only on Core.
- Move `RuntimeAppReadResources` separately from the upload code. Its package-only
  interface remains available to the other Workflows facades through explicit
  imports. There is no re-export and no Runtime, Provider or store moved to Core.
- Preserve paging/snapshot revision checks, cursor bounds, 64 MiB accumulated
  page bound, Artifact byte/range/digest checks, sensitive-data handling, local
  user-selected export and original failure semantics. JobControl still verifies
  fresh job identity and only requests cancellation; it never reports a request
  as a completed cancellation or changes server-side ownership admission.
- History view/filter dependencies and global job inspector consume ClientKit
  directly. Other App/Workflows consumers import moved types explicitly; their
  remaining execution dependencies are not claimed retired.
- The nine trace parameter names have one ordered ClientKit display vocabulary.
  Provider profile values remain in Workflows. The HiLog UI fixture now encodes
  fixed sample summaries, without invoking the Swift analyzer; a Runtime-side
  test compares those samples to the existing analyzer output.

## Validation

Moved History application, History paging, and shared read-resource suites into
`ArkDeckClientKitTests`, whose dependency list is only Core + ClientKit. They cover
unknown/stale identities, paging failures and retries, malformed/incomplete
Artifacts, integrity/export failures, and fresh cancellation checks. Existing
architecture assertions follow the new source locations; cross-module consumer
checks retain their original test targets.

Focused Swift build/tests: **PASS**, 49 ClientKit tests + 79 Contract tests
(128 total). Command from `Packages/ArkDeckKit`:

```sh
swift test --disable-sandbox --disable-automatic-resolution --filter \
  'ArkDeckClientKitTests|DiagnosticSessionReadingContractTests|ArchitectureBoundaryContractTests|OverviewRunRecordContractTests|RuntimeWorkspaceThreadContractTests|TraceApplicationFacadeContractTests'
```

The Contract selection includes 15 architecture, 29 diagnostics reader,
16 Overview, 7 workspace thread and 12 Trace facade tests. The new fixed HiLog
sample/analyzer byte-equivalence test passes. Log:
`/private/tmp/arkdeck-clientkit-history-read-tests.log` (local, not committed).
`git diff --check`: **PASS**. Normalized comparison against the stacked base
confirms unchanged History, JobControl, workspace-kind and read-resource
algorithms, apart from import/access modifiers and the shared trace-name source.

Unified repository gate and App build-for-testing: pending. No installation,
launchctl, signing change or device execution was performed.

## Remaining scope

This is a source/module extraction using the existing production transport. It
is not signed standalone Rust App acceptance or completion of SPK-8. The isolated
Rust History ingress first slice admits only health/filter; full History reads
and typed App job cancellation require their own explicit ingress implementation
and verification. Wire DTO generation, remaining facades, final installation,
Swift Runtime retirement and GJ real-device evidence remain incomplete.
