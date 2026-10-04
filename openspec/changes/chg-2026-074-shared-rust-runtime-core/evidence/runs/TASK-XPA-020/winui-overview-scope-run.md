# TASK-XPA-020 — WinUI Overview device scope and remote server, 2026-10-04

- Task: sweep item 4 (part) of `winui-history-handoff-run.md`: the macOS Overview device bar
  (`OverviewRecordView.deviceScope` and `remoteServerScope`). Base: branch
  `agent/xpa-020-winui-overview-scope-20261004`, one commit on `origin/main` `1f05dce0`; nothing is
  force-pushed. Host and boundaries as the earlier WinUI runs; no device, `hdc` or DAYU200.

## What was built

| Part | Content |
| --- | --- |
| `App.Core/Presentation/OverviewScope.cs` | macOS `OverviewCapabilityApplicationFacade.targets(from:)` (authorized, current, adopted, with a binding; one per Target) and its scope rule (the person's choice while online, else the only one, else none); the facts line; the remote-server binding states. |
| `SurfaceLoader.OverviewAsync` | Also reads `device.observations` (the same read as the Device page). |
| `OverviewPage` | The device bar: name or picker (`overview.record.device.*`), facts, and the remote build server (`overview.record.remoteServer.*`) read from the App's bindings and sources (no Runtime call). |
| Strings | 5 `Localizable` keys, values unchanged. |

Delegated minor decision (pending the next rulings batch): the bar is the first card of the
Windows Overview, above the Runtime's diagnosis; the capability matrix beside it on macOS needs the
HDC tuple (sweep item 4) and is not part of this slice.

## Checks on the reference host

Local targeted checks (2026-10-04, on `1f05dce0`; logs in the session scratchpad `x3/overview-full.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive; SHA-256 `1b634cad4ef9be7f091aa46cba585873afafd97081dc4be9a4d6594f61f95dd7`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 136 passed (`OverviewScopeTests` 3) |
| ClientKit.Tests | 42 passed, 1 skipped (needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, the daemon above) | 114 passed, 1 skipped (needs an installed package), 1 failed: `TheRecoveryBannerIsAnnouncedWhenTheDaemonGoesAway` — the `outage` scenario answered the start's first four connections, and Overview now makes five; it answers five now, and the recovery-banner tests and `OverviewScopeFlowTests` then passed twice in a row |
| the four generators `--check` | exit 0 |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

## Not done here, and why

Overview's next step, run threads, resume sheet and the HDC environment block (sweep item 4); the
capability matrix needs the Windows HDC tuple (CHG-2026-078).

CI: to be recorded by the PR's hosted run; not verified here.
