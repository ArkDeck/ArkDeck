# Windows native component mapping — 2026-10-07

This increment makes the existing `app.design.components` source mapping reviewable and
mechanically checked within the adopted TASK-XPA-020 H.1/H.3 native semantic projection scope.
It adds no production gallery route, Runtime action, transport, resource or string. The
historical 32-preview design gallery remains a synthetic JS design mirror; it is not 32 native
WinUI previews or proof of pixel equivalence, human Narrator use or hardware acceptance.

`windows/spec/windows-component-map.json` closes all 59 value exports from `@arkdeck/ds` and
all 32 `.design-sync/previews/*.tsx` files. Its 23 groups reference actual production source
anchors and exact existing semantic snapshots or named scripted UIA method/identifier sets.
The four retired Automation families remain retired references. Windows TitleBar/Mica/icons
are explicit platform chrome, and the upstream ArkTrace canvas illustration remains outside
the controlled export census. Native source references establish mapping, while the existing
UIA cases remain the separately executable behavioral evidence.

Design-only geometry/interactivity is recorded honestly: DiagnosticTimeCursor maps to the
current selection/alignment footer without claiming a draggable slider; DiagnosticScreenThumbnail
maps to screenshot applicability/absence prose without claiming a bitmap widget; tracks/points
are original saved timeline and mark projections. The design-only preset picker is not promoted
to a new preset catalogue. Any future missing accepted action/state must remain a delivery gap;
this mapping cannot declare it implemented through a synthetic fixture.

`WindowsComponentMappingTests` verifies the complete export/preview census, closed fields,
in-root existing source paths and exact anchors, real `[TestMethod]` declarations, the actual
snapshot scenario/identifier sets, and identifiers asserted inside each named scripted flow.
Negative mutations refuse missing/duplicated/invented components or previews, missing/outside
sources, nonexistent anchors/cases/snapshots/identifiers, mismatched scenarios and widened claims.
Scenario proof uses the actual `ScriptedDaemon.Scenarios` registry and the exact transport argument
pair in the named method or its directly called unique Launch helper. A `succeeded` status literal
and a registered scenario belonging to a different launch both have explicit refusal regressions.
The map does not change any frozen oracle or Core/schema vocabulary. Coverage promotion is
owned by the integration layer after actual checks and review; eight new accessibility rows
alone do not establish the 32-preview gallery.

## Local targeted checks

All commands ran sequentially in `D:/src/ArkDeck-wt/soak-owner` during the explicitly granted
single software-check window. The source parent remained
`cdf137be0cf67250d4d1c834f75cfc9122856688`; no parent synchronization occurred during checks.
The task helper clears inherited `ARKDECK_*`/`OHOS_*` live opt-ins and creates new logs/results.
Log root: `D:/src/ArkDeck-wt/tools/logs/windows-component-map-20261007/`.

| Command / working directory | Actual result | Log |
| --- | --- | --- |
| `npm.cmd run build` / `docs/design/arkdeck-ds` | Exit 0, 7.698 s; type-check and 32 previews bundled independently | `ds-build-2.log` |
| `npm.cmd test` / `docs/design/arkdeck-ds` | Exit 0, 2.154 s; 86 passed, 0 failed/skipped | `ds-tests-2.log` |
| `dotnet restore App.Tests/ArkDeck.App.Tests.csproj --configfile <task-public-only-nuget-config> -p:RestoreDisableParallel=true` / `windows` | Exit 0, 3.843 s; existing central versions and reusable NuGet package cache | `mapping-restore-2.log` |
| `dotnet test App.Tests/ArkDeck.App.Tests.csproj --no-restore --filter FullyQualifiedName~WindowsComponentMappingTests --logger trx;LogFileName=component-mapping.trx --results-directory <fresh-task-results> -m:2 -p:UseSharedCompilation=false` / `windows` | Exit 0, 14.769 s; fresh TRX verifies 17 passed, 0 failed/skipped | `mapping-3.log`, `mapping-3-trx/component-mapping.trx` |
| `C:/Program Files/Git/bin/sh.exe scripts/check-sdd.sh`, with the existing compatible Python explicitly selected / repository root | Exit 0, 2.932 s | `sdd-3.log` |

The existing DS test initially failed on Windows: `workspace-interactions.test.mjs` compared
native `path.relative` backslashes with the published forward-slash repository path census
(`ds-tests-1.log`: 85 passed, 1 failed). The repair imports `node:path.sep` and normalizes only
the two actual source/preview lists. Exact `deepEqual`, source-link and all 86 criteria remain.
The passing 32-preview build was not repeated because this repair changes only test comparisons.

Preparation and non-test attempts are retained separately, without treating them as invalid
load runs or successful verification:

- `ds-build-1.log`: exit 1 because fresh-worktree TypeScript dependencies were absent; no preview
  verification occurred. The existing lockfile dependencies were then installed once and reused.
- `ds-dependencies-1.log`: exit 1 because the helper selected the same npm config as user/global;
  separate task-owned public-only configs corrected that setup error.
- `ds-dependencies-2.log`: exit 1 because sandbox networking denied public npm registry access.
  The explicitly authorized public-only install completed in `ds-dependencies-3.log`, exit 0.
- `mapping-1.log` and `mapping-2.log`: exit 0 with no test output/TRX, and therefore **not tests**.
  Fresh-worktree assets were absent, so `--no-restore` had no imported MSTest test-project metadata.
  One explicit targeted restore resolved that prerequisite; the final command requires the real TRX.
- `mapping-restore-1.log`: exit 1, NU1301/NU1900 from sandbox-denied public nuget.org networking;
  the authorized public-only restore succeeded in `mapping-restore-2.log` without new cache setup.
- `sdd-1.log`: the helper could not launch unqualified `sh` (WinError 2), so SDD did not run.
  `sdd-2.log` reached SDD but exit 2 because PATH `python3` lacked PyYAML. Selecting the existing
  compatible Python via the supported `ARKDECK_PYTHON` input produced `sdd-3.log` exit 0; no
  interpreter/dependency installation or production configuration change was made.

Only the new mapping class ran from App.Tests. Existing source-referenced UIA flows were not
rerun here; their reference is a mechanically checked mapping, not a new native execution claim.
No full WindowsApp coverage suite, App build, GUI/UIA or complete unified gate ran in this packet.
Integration-owned metadata/coverage checks remain outside this packet.

No Runtime, installed account, DevEco/Harmony SDK, HDC, device or private Raw is read or invoked.
The actual JS build and source/fixture mapping checks are software-only. The source anchors and
scripted fixture references do not prove 32 native previews, native pixel equivalence, human
Narrator behavior or hardware acceptance. `git diff --check` completes the final source packet
verification; its task-local log is `diff-1.log` (exit 0).

## CI

No PR/run exists for this uncommitted increment. CI remains pending; no local software fixture
or synthetic preview can substitute for hardware acceptance or human approval.
