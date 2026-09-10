# TASK-XPA-012 Xcode dependency-pin scope request

Base: `7b43ea0fabb697e5d0550df5d2a6b8264410362f` (protected main).

XPA-AC-1 requires the current metadata field set and refusal of one extra key.
ArkTrace PR #24 supplies the shared strict reader without changing writer bytes:
https://github.com/ArkDeck/ArkTrace/pull/24
Maintainer `lvye` approved it and merged `e6e3133d410fbd7455df17c9486dcd369607e97f`
on 2026-09-10. Its required CI passed. The upstream diff from the existing pin
contains only the cache reader, its focused tests and integration documentation.

ArkDeck has an independent ArkTrace revision in `project.pbxproj`, in addition
to its Swift package manifest and two resolution files. The existing Task scope
permits this project file only for UI-test registration. A path match alone does
not authorize a package change, and an in-band Scope-Extension cannot redeclare
a path already covered by the base allowlist.

This openspec-only request permits exactly the ArkTrace revision replacement
from `c85731b0f903261bd69cf789027774fde615c8de` to
`e6e3133d410fbd7455df17c9486dcd369607e97f` in that project file. No target,
product, build setting, signing configuration, schema, Catalog, Runtime owner,
acceptance criterion or Task status changes. The adjacent manifest/resolution
files are separately declared under CHG-2026-076 in the implementation work.

The revision replacement is implemented only after this scope request receives
maintainer review and merge. The harness and authorized adapter/tests continue
independently; this request does not present a partial implementation PR.

Validation:

- `sh scripts/check-sdd.sh` with the pinned Python environment: exit 0,
  zero errors/warnings and 121 acceptance IDs.
- Complete-diff unified planner with `--merge-base --include-worktree --run-local`:
  exit 0; all selected common checks passed. Product lanes were not selected for
  this openspec-only change.
- Final committed path preflight is run before push; hosted CI belongs to the PR.

Logs: `/private/tmp/xpa012-xcode-pin-scope-sdd.log` and
`/private/tmp/xpa012-xcode-pin-scope-gate.log`. No nightly, cutover, rollback or
GJ-1 acceptance is claimed by this scope request.
