# Device list ClientKit extraction

Base: protected main `81957589` (merge `2f164936`); the extraction was reviewed against
`510b46508d8719318114a17c2567b701297efb65`. The normalized production comparison was
repeated against `510b4650` after Artifact publication integration at `c1d97133` and
passed: only the documented imports, display enum name and package access differ.
TASK-XPA-019 / SPK-8 remain incomplete.

| Already on `main` | This slice | Still remaining (TASK-XPA-019) |
|---|---|---|
| ClientKit transport and History filter (#1976), History readers and JobControl (#1982), generated History filter wire models pending in #1986 | `DeviceListApplicationFacade`, candidate/history decoration models, the bounded read-only authorization wait, response decoder and UI fixture move from Workflows to ClientKit (fourth facade); Devices imports ClientKit | the other eleven Workflows facade files (next by Rust readiness: `RuntimeTraceCacheApplicationFacade`, `HDCApplicationDiagnosticsFacade`), SPK-8 signed standalone App acceptance, the UI suites per facade |

The App-facing DeviceList facade, candidate/history decoration models, bounded
read-only authorization wait, response decoder and UI fixture move from Workflows
to ClientKit. ClientKit retains only its existing Core package dependency.
The Devices SwiftUI surface imports ClientKit instead of Workflows; the other
consumers explicitly import the actual model owner. There is no re-export shim.

The only Provider-owned exposed type was HDCAuthorizationState. A display-only
DeviceAuthorizationPresentation keeps its seven case shapes, without importing
Provider retry policy or HDC execution. This enum is not Runtime authorization.
The existing HDC diagnostics facade still consumes the shared read transport via
package access and remains in Workflows; none of its execution behavior moves.

A normalized comparison of the complete production facade against main is
identical after accounting for imports, the presentation enum name and package
access for the existing shared read transport. The request remains
`device.observations`; this change does not adopt, submit, cancel or manage HDC.
No transport allowlist or standalone Rust availability claim changes.

Five existing decode, stale-state, target-fact binding, bounded wait and closed
surface tests move into the independent Core/ClientKit test target. The closed
surface test additionally checks forbidden imports and the Devices App import.
Runtime owner integration tests remain in ArkDeckContractTests with an explicit
ClientKit import. The History architecture source lookup follows the new file.

Completed first: static dependency review, normalized production comparison and diff
whitespace check (the paragraph below was written before compilation). Planned focused suite: ArkDeckClientKitTests, DeviceCandidatesContractTests,
HDCRuntimeDiagnosticsProjectionContractTests, RuntimeHistoryApplicationContractTests,
ArchitectureBoundaryContractTests and affected candidate-model consumers.
The final unified entry must also build the App for testing. Signed standalone
Rust UI acceptance, installed activation and physical-device acceptance are not
claimed by this extraction.

## Verification

Unified gate (`plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, `ARKDECK_PYTHON` and the planner from a
virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0):

| Run | Head / merge base | Lanes | Result | Log |
| --- | --- | --- | --- | --- |
| 2026-09-19 11:2x–11:30 CST (the executing session recorded no result before its usage limit) | `336bfb75` / `510b4650` | swift, App build-for-testing, design-system | **exit 0** | `/private/tmp/arkdeck-clientkit-device-list-unified-main510-20260919.log`, SHA-256 `4361be9d820bf9a49c18176d6bfcd296cb946483a7bfb7297461ecb30336f950` |
| 2026-09-19 13:50:06–13:59:56 CST | `2f164936` / `81957589` | swift, App build-for-testing, design-system | **exit 0**: SwiftPM full lane 2687 tests without failure, `** TEST BUILD SUCCEEDED **`, design-system 83/83, `check-sdd` 0 errors | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/devicelist-gate-2f164936.log`, SHA-256 `6a3d1310b99e39fa68d5b3ea72d4437ab1c757d0510facfd401f7190f5a35c3f` |

The merge with `81957589` brought only Rust and evidence changes: `git diff 336bfb75
2f164936` outside `rust/` and the change's `evidence/` is empty, so both runs test the
same Swift and App sources.

The planned focused suites all ran inside the full lane of the second run: the
`ArkDeckClientKitTests` module (54 tests, including `DeviceListApplicationContractTests`
5), `DeviceCandidatesContractTests` 12, `HDCRuntimeDiagnosticsProjectionContractTests` 4,
`RuntimeHistoryApplicationContractTests` 36, `ArchitectureBoundaryContractTests` 15, and
the affected candidate-model consumers `OverviewCapabilityApplicationFacadeContractTests`
5, `UIDumpApplicationFacadeContractTests` 15 and `ViewerRealDumpShapeTests` 10. The App
build-for-testing lane is the `run-xcodebuild.sh build-for-testing` step.

Not run: the Devices UI suites (`ArkDeckHDCUITests` `DeviceRecordingUITests`,
`DeviceStaleFrameUITests` via `sh scripts/ci/run-ui-tests.sh`). The host console was locked
(`IOConsoleLocked = Yes` from about 13:29 CST), so no UI test can drive the App; the App-side
diff is the `DeviceWorkspace.swift` import (`ArkDeckWorkflows` → `ArkDeckClientKit`) and its
comments. Signed standalone Rust App acceptance, installed activation and physical-device
acceptance are not claimed.
