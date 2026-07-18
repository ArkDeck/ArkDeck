# TASK-RLC-001 headless consolidation run

- Date/time: 2026-07-19 07:37:49 CST (Asia/Shanghai)
- Base revision: `840e8306e0f8539072c3931384a21a80269d9027`
- Base tree: `4391a42e2b7e1bde49b69c1211a707a46c356c18`
- Environment: macOS 26.5.2 (25F84), arm64; Xcode 26.6 (17F113); Swift 6.3.3;
  swift-format 6.3.0; CPython 3.14.6.
- Evidence class: Git-object/platform audit plus local fake-child, temporary-file, and
  loopback-only contract tests.
- Explicit exclusions: real HDC, device, GUI/XCUITest, NSOpenPanel/PowerBox, non-loopback
  network, hardware, platform conformance, support, and release evidence.

## Objective and scope result

All three proposal-pinned source objects were readable. The M1 source commit and its human-reviewed
squash have identical parents and trees; every source path is byte-identical in the execution
base. PD implementation and blocked-record paths are also byte-identical in the execution base.
Therefore this run required no Swift, App, Xcode, or PD source edit. The implementation delta is a
provenance ledger, this run record, evidence-index update, and the TASK-RLC-001 status draft only.

No old M1/PD evidence was edited, copied, or reclassified. The full 34-path inventory, blob OIDs,
runtime reachability, source-task AC debt, consumer disposition, and rollback point are in
`../../legacy-import-manifest.md`.

## Commands and results

| Command / audit | Result |
| --- | --- |
| `git show -s --format=... <three fixed OIDs> <M1 squash> <base>` | pass; full OID, parent, tree, dates, and subjects resolved |
| `git diff-tree --no-commit-id --raw --no-abbrev -r <fixed OID>` for all three inputs | pass; 20 M1 paths + 12 PD implementation paths + 2 PD blocked-record paths inventoried with full blob OIDs |
| `git diff --name-status 21c2e218... 840e8306... -- <M1 paths>` | pass; empty diff |
| `git diff --name-status 0076e44d... 840e8306... -- scripts/partition_decode` | pass; empty diff |
| `git diff --name-status 0db5f22c... 840e8306... -- <PD change path>` | pass; empty diff |
| `git ls-remote origin refs/pull/105/head` | pass; exact result `ae708518ce6cc8bbd5ad39943d948b2d81209f03` |
| forbidden public HDC authority declaration `rg` scan | pass; exit 1/no matches for command, runner, lifecycle executor/protocol, lease, raw observation, durable store, or lifecycle use case |
| closed HDC authority declaration `rg` inventory | pass; concrete authority types are module-internal or `package` |
| App import scan | pass; App HDC files import Core/Workflows/UI frameworks only |
| App direct authority token scan | pass; exit 1/no Process request/executor, HDC command/executor/Supervisor, argv, spawn, or forbidden module import |
| shell/global-environment-write scan | pass; exit 1/no shell API or parent/global environment mutation |
| PD fd-only static inspection | pass; regular/read-only `fstat`/`F_GETFL` gates precede `dup`/`fdopen`; no archive-path fallback |
| `swift format lint --strict <15 fixed-source Swift files>` | pass, 0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter ProcessExecutorContractTests` | pass, 15 tests / 0 failures |
| `swift test --package-path Packages/ArkDeckKit --filter JobToolchainIntentContractTests` | pass, 4 tests / 0 failures |
| `swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests` | pass, 36 tests / 0 failures |
| `swift test --package-path Packages/ArkDeckKit` | pass, 233 tests / 1 existing manual sleep/wake skip / 0 failures |
| `scripts/check-sdd.sh` | pass, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | pass |

No command in this run invoked `hdc`, a device tool, the PD broker/build/collector, Xcode UI tests,
or a network client. The process contracts launched only system/local fixtures. HDC contracts
selected `ArkDeckFakeHDCFixture` by explicit path. The non-loopback endpoint case logged a string
to that local fake and made no network connection; the managed-ownership fixture used one
ephemeral loopback listener and stopped it.

## Instrumented safety conclusions

- Process path substitution, same-inode mutation, symlink/invalid descriptor, and atomic-gate
  invalidation all fail before child launch. Atomic invalidation observed child launch count `0`.
- Missing durable proof produces no fake-HDC invocation file. Lease invalidation before launch
  keeps invocation count `0`; a reused confirmation cannot launch a second child.
- External/unknown automatic server failures generate no lifecycle dispatch/audit. The subserver
  vector records only fixed `checkserver` and zero `spawn-sub`/`killall-sub` command.
- Unknown generation/impact, incomplete launch outcome, missing terminal reconciliation, and
  manifest tuple mismatch remain fail-closed.
- Installed-real-HDC, real-device, non-loopback-network, automatic-lifecycle, subserver-mutation,
  device-migration, and PD-interactive-collector dispatch counts are all `0`.
- Explicitly confirmed lifecycle tests invoke only the repository fake child and do not constitute
  real HDC, hardware, platform-conformance, or source-task acceptance evidence.

## Change-local binary acceptance

| Test ID | Result | Evidence |
| --- | --- | --- |
| `TEST-RLC-LEGACY-IMPORT-001` | PASS | all three OIDs/parents/trees resolve; 34 changed paths have full source/current blob disposition; M1 source equals reviewed squash tree; no branch name or worktree is source authority |
| `TEST-RLC-FAIL-CLOSED-001` | PASS | closed public surface, App import/authority and shell scans, fd-only PD audit, 15+4+36 dedicated tests and 233-test suite; all prohibited dispatch counters `0`; collector not run |
| `TEST-RLC-NONBLOCKING-001` | PASS | M1-006 and PD-001 remain `blocked`/non-done with original debt; their completion is not an RLC dependency; M1-007/M1-008/M0B-002/UD-001/FA-001 dependencies were not edited or bypassed |
| `TEST-RLC-AUDIT-ROLLBACK-001` | PASS | one TASK-RLC-001 implementation branch contains only allowed CHG-014 evidence/status paths; reverting its eventual merge removes the consolidation record but preserves independently reviewed source bytes/evidence; no secret/sensitive artifact recorded |

## Deviations and remaining risk

- A real HDC binary is installed on the host but was a forbidden, unused input. Its presence is
  not a support claim and it was not executed.
- No product-code repair was necessary because PR #105 already merged the exact M1 source tree.
  Reverting this implementation PR therefore rolls back the consolidation/audit claim, not those
  pre-existing source bytes.
- TASK-M1-006 still lacks approved production integration probe families and a passing current
  signed Sandbox XCUITest. TASK-PD-001 still lacks fresh interactive evidence and an approved
  DEFLATE sliding-history boundary decision.
- The task deliverable requiring `Consolidated by TASK-RLC-001` disposition in the two source-task
  files must be delivered by a separate governance/status PR. It is intentionally not mixed into
  this implementation PR, so TASK-RLC-001 remains `in_progress` rather than being drafted `done`.
- No consumer dependency was revised. M1-007/M1-008 remain non-executable while their declared
  dependencies are unsatisfied, regardless of their pre-existing textual status.

Required completion-boundary statement:

> source tasks remain non-done and all unresolved gates remain explicit; no conformance/hardware/
> support/release claim

## Rollback

The clean pre-implementation rollback point is
`840e8306e0f8539072c3931384a21a80269d9027`. After merge, use a normal revert of the single
TASK-RLC-001 implementation merge. Do not delete or rewrite M1-006/PD-001 commits or evidence.
