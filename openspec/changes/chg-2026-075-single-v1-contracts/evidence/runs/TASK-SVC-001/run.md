# TASK-SVC-001 execution record

Status: implementation and host verification complete; submitted for PR review together with the user-requested scope supplement. Task `done` is proposed with this vertical delivery. The series is incomplete; no main approval, merge, change verification or hardware claim.

Branch: `agent/task-svc-001-single-v1`. The working tree was initially clean. The complete implementation is saved in one local commit, with subject `refactor(TASK-SVC-001): unify clients and runtime on the current v1 contract`.

Initial base: `a8ebf540ed641268ae0be06e712430f631c28b3f` (CHG-2026-075 proposal, #1726). Final validation base: `03d6a9cc5219510997a69a2dc5f4f2c4a9f0125a`. The branch was rebased onto the fetched current main, retaining its Settings and CI fixes.

## Implementation and acceptance scope

- **SVC-AC-01:** one current control registry, exact version `1.0.0`, generated contract identity, and 96 retained methods mapped from all 118 base dispatch names in [methods.md](../../../methods.md). UDS and XPC verify current health on the actual connection before business dispatch; reconnects check again. Removed negotiation, required-major options, specialized uploads and duplicate resource branches. Capability management placeholders remain unavailable.
- **SVC-AC-02:** CLI, Executor, App upload and production resource readers use the same current typed resources. App uploads retain kind/owner/target restrictions, generation/offset/digest checks and no abort after ambiguous commit. Readers assemble immutable Job timeline and Artifact inventory pages locally. Device screenshots, gestures and recordings now use these shared readers, with range identity, bounds and final digest validation. Discovery uses the current observation owner and authorized display facts; discovery does not adopt.
- **SVC-AC-03:** structured refusal details and unknown transport outcomes propagate without replay. CLI output format does not select a protocol. Submission waiting retains a single result and bounded deadline. Nested bounded clients cannot renew the caller's budget; direct health checks remain bounded.
- **SVC-AC-04:** the current Runtime request model, codec, direct Codable and durable Job request load share exact version, key and retired-authority validation. Removed campaign fields remain explicit refusals, including null input. Strict duplicate-key/size/newline parsing was extracted for the existing durable consumers without changing their record layouts.

No authority, trusted-fact, hardware-evidence, Catalog, Constitution or Core acceptance requirement was rewritten. Durable Journal/Manifest layout migration remains SVC-002/003 scope. Provider dispatch in this Task occurs only inside isolated host fixtures.

## Approved scope additions

The execution contract required a concrete diff and maintainer review for three necessary paths outside its allowlist. The user answered **“同意，继续”** on 2026-09-05. All three reviewed patches were applied without another confirmation:

1. [Device controls](device-control-scope-review.patch): `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceControlFacade.swift` migrates production screenshot, gesture and recording readers to current Job detail, tagged-owner Artifact pages and bounded ranges. The injectable request closure permits production-reader tests.
2. [API baseline](api-baseline-scope-review.patch): `Packages/ArkDeckKit/APIBaseline/Sources/APIBaseline/APIBaseline.swift` removes its reference to the retired `campaignReservation` property. Compilation found that the proposal's replacement `reviewedPlanDigest` is a wire-only precondition, not a public Swift property. The final baseline checks the existing public `authorization` property instead; plan precondition validation is unchanged.
3. [Local diagnostic UI fixture](diagnostic-fixture-scope-review.patch): `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DiagnosticSessionUIFixture.swift` emits current Job detail/status and Artifact page shapes for its two explicit local sample providers. These samples are not raw Artifacts or hardware evidence.

The original proposal patches remain as the review record, with blank context-line whitespace normalized; the source diff is authoritative. After reviewing these patches, the user explicitly requested “你随 PR 一起提交”. The same implementation PR therefore adds exactly these three paths to TASK-SVC-001 and proposes its done status. The checker and safety requirements are unchanged; the base-tree path check below remains red until resolved through review.

## Final host verification (2026-09-05)

Commands ran from the repository root. Logs under `/tmp` are development logs, not hardware evidence.

| Command / check | Result |
| --- | --- |
| `python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local` | **PASS**, exit 0, `/tmp/svc-001-final-gate.log`. Public checks; 83 design-system tests; Swift full-parallel lane with 2,420 scheduled cases; one serialized process-identity race case; five Viewer scale cases; App build-for-testing reports `TEST BUILD SUCCEEDED`. Opt-in hardware tests remain opt-in. |
| `python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --check` | **PASS**, no generated contract drift. CLI generated-bundle equality is also covered by the full Swift gate. |
| `python3 -m unittest discover -s scripts/bench -t scripts -p 'test_*.py'` | **PASS**, 122 tests, `/tmp/svc-001-bench-approved.log`. Controlled elevation permits the RSS test to inspect its own host process. |
| `git diff --check origin/main` | **PASS**, including the committed proposal patch files. |
| Approved-path focused tests | Diagnostic sessions, Overview and existing Device cases passed. After correcting the API key path, six focused cases passed in `/tmp/svc-001-device-production-tests.log`: API baseline, paired production Device/CLI reader, and four new Device provider tests. |
| `python3 scripts/check_pr_paths.py --repo-root . --preflight --base-revision origin/main --head-revision HEAD` | **FAIL**: exactly the three user-approved source additions remain outside the Task's base-tree Allowed paths. Full diagnostic: `/tmp/svc-001-path-preflight.log`. This is independent of the green build/test gate. |

Production boundary coverage includes:

- `ArtifactResourcesContractTests.testDeviceProductionReaderAndCLIReadTheSameDaemonScreenshot`: the actual Device provider and real CLI consume the same isolated daemon's screenshot, including multiple App ranges and foreign-target refusal; zero new dispatch.
- `JobReadResourcesContractTests.testLongUnicodeTimelineIsReferenceAndLosslessBoundedPages`: production App reader and real CLI consume the same daemon's long Unicode timeline without changing entry boundaries; zero dispatch.
- `DurableImportContractTests.testAppAndCLIUseTheSameTypedImportWithoutSharingUploadOwnership`: real CLI and production App upload serialization share a daemon; CLI-owned upload reuse and App workspace-patch import are refused, with zero Jobs.
- `DeviceProductionProviderContractTests`: recording pages and both verified products; current gesture timeline pages; unknown gesture outcome without replay; foreign owner, changed range identity/bounds and corrupt bytes fail closed.
- `RuntimeAppReadResourcesContractTests`: malformed tags/inline entries, foreign Job references, unfinished or reordered fragments, mixed revisions and repeated cursors never return partial timelines.

Earlier full-gate checkpoints were red: the initial run exposed the three missing scope migrations and stale CLI fixtures. After applying the reviewed paths, one ScreenshotEncoding fixture still used the retired `sha256` key; it now uses `artifactDigest`. The final full gate above includes these corrections and the latest main. No assertion or safety requirement was relaxed to obtain a pass.

## Same-PR delivery and next dependency

The preflight reads Allowed paths exclusively from the base commit. It does not accept conversation approval, and its supplement mechanism only permits new change/evidence documents; it cannot authorize these three production/baseline paths. The bot PR workflow runs this same preflight before creating a PR.

The user explicitly instructed that the approved scope additions travel with the implementation PR instead of waiting for a separate main-side scope change. The Task document now contains those three exact paths and records this instruction. This is a reviewable scope supplement, not a claim that the base-tree preflight passes.

Because `agent-pr.yml` stops before PR creation on this unchanged preflight, the requested same-PR delivery uses direct PR creation with the connected GitHub account. The PR must disclose this authorship deviation and the static check failure. No check result, branch protection or workflow is altered. Independent maintainer review remains required; the submitting account cannot approve its own PR.

SVC-002 can start only after the SVC-001 implementation is reviewed and merged into protected main, as required by the series execution contract.

No UI assertion or real-device operation was run: this Task changes host contracts and readers. Published-operation hardware acceptance belongs to SVC-005; no `REAL_DEVICE_PASS` is claimed.
