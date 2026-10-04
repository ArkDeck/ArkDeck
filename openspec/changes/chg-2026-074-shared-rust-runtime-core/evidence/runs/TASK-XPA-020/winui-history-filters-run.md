# TASK-XPA-020 — WinUI History filters, older pages, saved filter and detail sections, 2026-10-04

- Task: sweep item 2 of `winui-history-handoff-run.md`: macOS `RuntimeHistoryView`'s
  filter sidebar, saved-filter menu, job table and Load Older, and
  `RuntimeHistoryFilterApplicationFacade`. Base: branch `agent/xpa-020-winui-history-list-20261004`,
  one commit stacked on `agent/xpa-020-winui-job-inspector-20261004`, per the stacked-PR rule of
  #2485. Host and boundaries as the earlier WinUI runs; no device, `hdc` or DAYU200.

## What was built

| Part | Content |
| --- | --- |
| `App.Core/Presentation/HistoryFilters.cs` | `HistoryFilterQuery` (activity, search, status, mode, Session, Target, time; macOS `matchesFilters`, newest first), the activity of a record (the Runtime's `workspaceKind`, else the operation), the Runtime wire names; `SavedHistoryFilter` (macOS list decoding: one filter at most, generation 1 without a time and later ones with one, canonical generations); the loader's `history.filter.list|save|delete` and `job.list` paging (`JobPageFacts`: `hasMore` and `nextCursor` agree). |
| `HistoryPage` | The filter card (`history.filter.*` pickers with ids per option, search, quick filters `history.activity.needsAttention`, `history.filter.preset.recentFailures`, `history.activity.selectedDevice`, Reset, the saved filter: Save, Apply, Delete, Reload), the list (`history.filter.resultCount`, `history.filter.empty`, `history.loadOlder`), all rebuilt from the Jobs already read. |
| History detail | macOS's sections: the summary (Session, outcome certainty, effect, started, the projection note, residue), the journal summary (`job.show`, paged; `history.detail.timeline.entries`), the correlation (the Session, operation and Target as the status states them, the Artifacts with digests, Show related Jobs as a Session filter), the evidence's observed model, firmware and transport, the parameters (the Trace parameters before and after a capture, compared as macOS `decodeTraceEvidence`, and the typed inputs), and the recovery state, last. |
| Scripted transport | `job.show` for the `jobs` scenario's Jobs. Scenario `history`: `recovery`'s Jobs in two pages and a stateful, generation-guarded saved filter. |
| Strings | 88 `HistoryLocalizable` keys (values unchanged) and 5 Windows-only lines. |

Delegated minor decisions (pending the next rulings batch):

1. **Filters are a card above the list** (macOS: a sidebar, or a popover when narrow); the
   activity is a picker with counts, as macOS's compact form.
2. **The saved filter's actions are buttons with a summary line** in words (macOS: a menu).
3. **The record date is the finish, else the creation** (the Windows status has no start time in
   `JobSummary`).

4. **The Trace parameter table is a list** of one line per parameter (name, before, after,
   comparison in words): a WinUI list reads row by row with a screen reader.

## Checks on the reference host

Local targeted checks (2026-10-04, on `b812bffc0`; logs in the session scratchpad `x3/history2-full.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive; SHA-256 `7db21ab1e44d1c104ab29f047b13542d8baf9f0d472a5042d726201c96ed4daa`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 159 passed |
| ClientKit.Tests | 42 passed, 1 skipped (needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, the daemon above) | 124 passed, 2 skipped (keyboard focus visual check; installed MSIX) |
| the four generators `--check` | exit 0 |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

Stacked on #2502 (`agent/xpa-020-winui-job-inspector-20261004`); the diff against that branch is this layer only.

CI: to be recorded by the PR's hosted run; not verified here.
