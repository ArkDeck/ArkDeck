# ClientKit History filter extraction — 2026-09-18

Scope: first production extraction within SPK-8 / TASK-XPA-019, macOS only.
This record does not claim SPK-8 completion or Rust UI acceptance.

## Delivered boundary

- `ArkDeckClientKit` is a SwiftPM library depending only on `ArkDeckCore`.
- The existing production raw libxpc transport moves from Workflows into ClientKit:
  persistent channels, daemon code-signing requirement, health/contract identity,
  response correlation, bounded waits, first-terminal completion and no replay are retained.
- The History filter facade, its closed presentation query/resource types and decoder
  move into ClientKit. The App explicitly imports and links ClientKit for this facade.
- Other App facades temporarily remain in Workflows and explicitly consume the extracted
  transport. The Swift History store and daemon temporarily consume the shared DTOs;
  ClientKit has no dependency on their implementation. There is no blanket re-export.
- Dedicated `ArkDeckClientKitTests` depends only on ClientKit and Core, with moved History
  facade and transport lifecycle tests plus explicit-null/conflict-without-replay coverage.

## Validation

- `plutil -lint ArkDeck.xcodeproj/project.pbxproj`: passed.
- `git diff --check`: passed at extraction verification.
- `swift test --package-path Packages/ArkDeckKit --filter
  'ArkDeckClientKitTests|RuntimeHistoryFilterStoreContractTests|ArchitectureBoundaryContractTests'`:
  passed, 24 tests (5 ClientKit, 4 History store, 15 architecture); zero failures.
  The first build required package dependency fetch permission. An earlier in-progress
  build had a stale source list while tests were relocated; the stable-tree rerun above
  compiled all package targets and passed.
- Final unified local validation passed (2026-09-19), using the pinned validation
  venv and the repository root entry below. Selected Swift full tests, App
  build-for-testing (`TEST BUILD SUCCEEDED`), Rust workspace/contract checks,
  clippy, deny and vet all passed. Log: `/private/tmp/arkdeck-clientkit-gate.log`.

  ```sh
  ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python \
    /private/tmp/arkdeck-validation-venv/bin/python scripts/ci/plan.py \
    --repo-root . --base-revision origin/main --head-revision HEAD \
    --merge-base --include-worktree --run-local
  ```

- The full gate exposed pre-existing Swift 6.4 SDK diagnostic spelling drift in
  three oracle compare paths. The narrowly scoped T2-only test compatibility
  and its eight passing tests are documented in `sdk-diagnostic-compatibility.md`;
  raw fixtures and production producers are unchanged. Initial failures were
  resolved before the final complete run. This is build/test evidence, not UI
  or real-device acceptance.

## Remaining acceptance

- Presentation wire decoding remains the existing hand-written strict decoder; generating
  typed models from `spec/control/methods/**` is still outstanding.
- History fixture UI tests still use the explicit in-memory provider. No fixture is
  counted as a standalone Rust daemon UI test or actual device evidence.
- A signed isolated Rust daemon History save/reload/delete UI run remains outstanding.
- No installation, LaunchAgent activation, device dispatch, entitlement change or Swift
  Runtime retirement happened in this slice. The other twelve facade migrations remain.
