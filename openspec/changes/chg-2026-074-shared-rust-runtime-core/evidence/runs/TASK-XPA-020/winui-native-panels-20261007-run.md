# TASK-XPA-020 — Native panels, host-action focus and accessibility, 2026-10-07

This test increment exercises the existing product pickers rather than supplying a picker
answer. Both common item dialogs are selected only by the launched App's PID and `#32770`
class; the existing native filename/folder field and confirmation/cancel controls are driven
through UIA patterns. It changes no picker implementation, Runtime operation or authority.

`NativePanelsFlowTests` measures two cases. History opens the sensitive 300,000-byte scripted
Trace's existing export preview and real `FileSavePicker`: cancel must preserve the task-owned
output directory and show no export phase; a later explicit save must match the complete
source bytes, SHA and count, across the whole Artifact reader. Settings › Diagnostics invokes
the real `FolderPicker`, without `--pick-folder`: cancel creates nothing; selecting a fresh
task-owned parent only previews; the separate explicit Export then publishes exactly the
three documented files. That case checks the closed manifest, total byte count, raw exclusion,
automatic-upload false, redacted/unverified tool metadata, and recomputes the approved scope
digest from the native selected-parent identity plus both whole source documents.

These cases observe filesystem/UI behavior. They do not claim measured zero RPCs on cancellation,
do not read account state or device data, and are not hardware evidence. The scripted Trace is
generated test data. Cleanup is limited to each exact fresh task-owned directory, with reparse
refusal before child traversal and deletion. The official AppSession harness owns the launched
App and its test preferences.

Sessions cleanup and inactive Trace-cache purge now explicitly make Close/Cancel the native
dialog default. Seven `HostActionFocusFlowTests` cases measure Enter, Escape, Close, modal
Tab containment and return focus in English and Simplified Chinese; explicit cleanup still
applies exactly the unpinned preview, and purge retains the active entry. The seventh case
measures the Device pointer keyboard path and refusal to repeat input on its stale picture.
Eight new accessibility rows measure Tab reading order and 2.25× text bounds in current/stale
Device-screen and recording/closed diagnostic-capture states. Existing assertions are retained;
these new asynchronous states settle against their actual UI status before measurement.
Narrator-by-ear was not measured.

## Local targeted checks

Executed sequentially after synchronization to Toolchains parent
`cdf137be0cf67250d4d1c834f75cfc9122856688` in `sv-layer`, in the explicitly coordinated native
window. The local runner clears inherited `ARKDECK_*`/`OHOS_HDC_*`, enables only
`ARKDECK_APP_UITESTS=1` and the exact newly built task-owned App for UIA, and uses Debug,
two MSBuild workers and `UseSharedCompilation=false`. No Runtime, account, installed RC,
Harmony SDK, HDC, device or private Raw was accessed. No full unified gate was run.

Commands were invoked through `D:/src/ArkDeck-wt/tools/native_panels_checks.py` with
`--execute --expected-head cdf137be0cf67250d4d1c834f75cfc9122856688`. Logs below are retained
under `D:/src/ArkDeck-wt/tools/logs/native-panels-20261007/`; each UI/Core invocation also has
its exact TRX and JSON. Selected results total **19 distinct passing cases, zero skipped**
(2 Core + 7 host-action + 2 native panels + 8 accessibility); successful overlapping Save
reruns are not added to that count.

| Phase / exact selection | Result | Log |
| --- | --- | --- |
| `core --suffix first`: `SessionsJobsTests.CleanupAppliesExactlyThePreviewedRemoval` and `SettingsWriteTests.APurgeRemovesInactiveDerivedDatabasesOnly` | exit 0; 2/2; 16.849 s | `core-first.log` |
| `app --suffix selectors-final`: `dotnet build windows/App/ArkDeck.App.csproj -c Debug -m:2 -p:UseSharedCompilation=false -p:Platform=x64` | exit 0; 0 warnings/errors; 16.695 s | `app-selectors-final.log` |
| `ui-host --suffix first`: `NativePanelsFlowTests` + `HostActionFocusFlowTests` | exit 1; all 7 host-action cases passed; 2 panel selector failures before output; 251.769 s | `ui-host-first.log` |
| `ui-panels --suffix selectors-final --app-pin app-selectors-final.json`: `NativePanelsFlowTests` | exit 0; 2/2; 45.412 s | `ui-panels-selectors-final.log` |
| `ui-a11y --suffix final --app-pin app-selectors-final.json`: only the four new Device/Diagnostics rows in each of `EveryActionIsATabStopInReadingOrder` and `NothingIsClippedAtTheLargestTextSize` | exit 0; 8/8; 112.105 s | `ui-a11y-final.log` |

The original Open-dialog filename selector (`1148`) did not describe WinRT Save/Folder
dialogs. Bounded, path-free metadata from the same App-owned `#32770` proved Save's
`FileNameControlHost` ComboBox → Edit `1001`, and Folder's Edit `1152`; each now has an
exact distinct selector. Search/file-list edits are never fallback candidates. Original
`ui-host-first.log`, both `ui-save-probe-dialog-*.log` failures and
`ui-panels-selector-fixed.log` (Save passed, Folder selector failed) remain unchanged. No
product picker injection, assertion relaxation or added sleep was used; the seven passing
host-action cases were retained because their source and product code did not change.

The final `app-selectors-final.json` pins all five tested sources and both actual current
output images before/after UIA: `ArkDeck.exe` SHA256
`31d5a268686453117811e234a3951fbf4c6f5e5df45947a5ab1f9a01056cc933`, and `ArkDeck.dll` SHA256
`5f8a9344061c6a59f4a83b507f5ee5bcdb2ea5bb0e778d88f833302f2f342db6`.
The executable is the .NET host; the DLL pin also binds the managed implementation.
Original build pins/logs were retained. Native dialog PID, filesystem and keyboard/UIA
projections are software proof only; no hardware, RPC-count or audible Narrator claim follows.

Generated strings (`generate-ui-strings.py --check`) passed exit 0 (`strings-final.log`).
SDD passed exit 0, zero errors/warnings (`sdd-final.log`); final note-inclusive SDD and
`git diff --check` are retained as `sdd-freeze.log` and `diff-final.log` respectively.
The six-file source/note freeze is saved locally as `source-shas-final.json` in the same
log directory; it includes every untracked source byte and this run note. Root owns Git.

## CI

Not published or run. Root owns final integration, publication and maintainer review.
