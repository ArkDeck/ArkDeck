# TASK-XPA-020 — WinUI global Job recovery banner, 2026-10-04

- Task: sweep item 3 of `winui-history-handoff-run.md`: the macOS `GlobalRecoveryBannerView`
  (`ArkDeckApp/Features/Jobs/GlobalJobInspectorView.swift`) and
  `RuntimeJobSummaryPresentation.requiresRecoveryGuidance`. Base: branch
  `agent/xpa-020-winui-job-recovery-20261004`, one commit on `origin/main` `08e8da7d`, with `origin/main` merged in after #2483 (the stacked copy #2489 was closed); nothing is
  force-pushed. Host and boundaries as the earlier WinUI runs; no device, `hdc` or DAYU200.

## What was built

| Part | Content |
| --- | --- |
| `App.Core/Presentation/JobRecovery.cs` | macOS `requiresRecoveryGuidance` (no established later epoch, and an unknown outcome, a person's action, or `waitingForRecovery`, `awaitingRebindConfirmation`, `resumeAtConfirmedSafeBoundary`, `userAbandonRequested`), the order (unknown, then a person, then the rest), each kind's title and guidance key. `JobSummary` keeps `supersededByRecoveryEpochId` and `resolvedByTargetAliasResolutionId`. |
| `MainWindow` | A row above the page (`jobRecovery.list`, at most 280 px, scrolling): the count (`jobRecovery.count`) and one card per record (`jobRecovery.banner`: title, guidance, Job · Target, `jobRecovery.openHistory.<id>`), refreshed from the Job Inspector's `job.list`; a change is announced. |
| Scripted transport | Scenario `recovery`: `jobs` with a Flash waiting for recovery and a HAP run to resume at a confirmed safe boundary. |
| Strings | 11 `JobsLocalizable` keys, values unchanged. |

Delegated minor decision (pending the next rulings batch): the kind is told by its title, in words
(macOS adds a symbol per kind; the text carries it for screen readers and high contrast); Open in
History is named with its Job.

## Checks on the reference host

Local targeted checks (2026-10-04, on `08e8da7d`; logs in the session scratchpad `x3/recovery-full.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive; SHA-256 `43a0226ef8fcb7b1fd144ec0185d054ab2eb11ae2501d48e9cd21001c47a2f2e`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 140 passed (`JobRecoveryTests` 2) |
| ClientKit.Tests | 42 passed, 1 skipped (needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, the daemon above) | 119 passed, 1 skipped (needs an installed package); `JobRecoveryFlowTests` and the `recovery` snapshot in both languages |
| the four generators `--check` | exit 0 |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

CI: to be recorded by the PR's hosted run; not verified here.
