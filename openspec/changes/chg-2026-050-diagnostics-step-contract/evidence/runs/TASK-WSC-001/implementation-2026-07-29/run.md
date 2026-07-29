# TASK-WSC-001 implementation run — 2026-07-29

- Base protected-main OID:
  `652ba4e885051abfc09c398bb992b373af769a26`
- Executor:agent (implementation; approval and merge remain maintainer actions)
- Evidence class:contract
- Hardware required/used:no/no
- Task-specific AC vectors — provider, HDC, network and device dispatch:0
- Raw device artifacts or logs committed:0

## Delivered closure

- Added a closed `actionRef { catalogId, actionId }` to the Operation Catalog
  step schema. It is required for `captureRemoteStdout` and forbidden for all
  other step kinds, including an explicit `null`.
- Bound all four published stdout steps to reviewed action identities:
  three `arkdeck-diagnostics/boundedHilog` references and one
  `arkdeck-diagnostics/componentTree` reference.
- Added the closed diagnostics stdout recipe contract with exact typed
  duration, filters and byte-budget bounds. Executable, argv, shell, raw
  command and caller remote-path surfaces remain unrepresentable.
- Made the generator reject missing, unknown, cross-catalog, misplaced and
  extra-field action references, preserve the exact pair in generated Swift,
  and detect generated drift.
- Extended JSON Schema and the Swift validator with the same two diagnostics
  actions and exact bounds. Contract vectors cover both boundaries plus
  malformed filter, wrong pair, out-of-bounds, extra parameter and
  command-shaped negatives before dispatch.

Generated Catalog digest:
`a5a1205c5b6a3202a87d99ded5af4cf50b8e4bd4bd47693c517aa249e0a6d717`.

## Verification

- `/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python
  scripts/catalog_gen/test_generate.py`:
  **34 tests / 0 failures**.
- `swift test --package-path Packages/ArkDeckKit --filter
  WorkflowStepContractTests --quiet`:
  **15 tests / 0 failures**. This includes the existing free-command and
  unregistered-command zero-dispatch vectors plus the new diagnostics
  positive/negative matrix.
- `swift test --package-path Packages/ArkDeckKit --filter Diagnostics --quiet`:
  **27 tests / 0 failures**.
- `swift test --package-path Packages/ArkDeckKit --quiet`, run from an isolated
  canonical `/Users/...` source path:
  **614 tests / 1 skipped / 0 failures**.
- `scripts/check-sdd.sh`:
  **0 errors / 0 warnings / 111 acceptance IDs**.
- `python3 scripts/test_check_pr_paths.py`:
  **50 tests / 0 failures**.
- `git diff --check`:pass.

The first full-suite attempts ran from `/private/tmp/arkdeck-wsc001`. They
consistently reported two unrelated resource-enumeration failures:

- `HDCGoldenResourceContractTests/
  testGoldenPackContainsExactRegisteredFixtureSetWithMatchingHashes`;
- `HDCProbeRegistryContractTests/
  testPackContainsExactPinnedResourceSetAndHashes`.

Both compare unresolved `/tmp/...` and canonical `/private/tmp/...` URL strings,
so the test worktree location produced relative paths prefixed with
`/private`. No related source or resource bytes were changed. Re-running the
same implementation bytes from the isolated canonical `/Users/...` path made
the complete 614-test suite pass without changing or weakening either
assertion.

## Acceptance result

- `AC-WF-001-01`:PASS. Existing registered-step/free-command negatives remain
  closed and dispatch count is 0.
- `AC-WF-001-02`:PASS. Every published stdout step has one exact registered
  action pair; missing, unknown, cross-catalog, misplaced, explicit-null,
  unrepresentable and drifted forms fail before Runtime/provider dispatch.
- Catalog / generated Swift / workflow JSON Schema / Swift validator
  parity:PASS.

## Deviations and residual risk

- Functional deviation:none.
- The `/tmp` resource-test path-alias behavior is an existing test-harness
  portability issue; it does not affect production code or the canonical-path
  full-suite result and was not changed because the affected tests are outside
  this task's allowed paths.
- This run is contract evidence only. It makes no hardware-support,
  real-device-capture or change-level verification claim. Change verification
  and archive remain a separate maintainer-reviewed PR.
