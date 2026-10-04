# TASK-XPA-020 — WinUI Job Inspector facts, 2026-10-04

- Task: sweep item 6 of `winui-history-handoff-run.md` (macOS `GlobalJobInspectorView.jobDetail`
  and `GlobalJobInspectorModel.readLog`). Base: branch `agent/xpa-020-winui-job-inspector-20261004`,
  one commit stacked on `agent/xpa-020-winui-debug-queue-20261004` (the Debug queue, itself on
  #2487), per the stacked-PR rule of #2485. Host and boundaries as the earlier WinUI runs; no
  device, `hdc` or DAYU200.

## What was built

| Part | Content |
| --- | --- |
| `JobInspector` | Ctrl+Shift+J on the toggle; a progress indicator while active; attention only while no later epoch is established; the established-epoch relation (`jobInspector.establishedCurrentEpoch`: the superseding recovery or the alias resolution, and its id); the residue line (`jobInspector.residue`); Read log locally (`jobInspector.readLog.<artifact>`) for a published standard log, the last 200 lines (`jobInspector.log.text`), or why not (`jobInspector.log.error`, `jobInspector.artifacts.unavailable`). |
| `App.Core` | `JobSummary` keeps `outstandingResidueCount`; `JobLogArtifacts` (the Catalog's `log` roles by operation, checked against `Catalog/operations`), the tail rule; `JobAsync` reads a Job's Artifacts only when its operation declares a log. |
| Scripted transport | The `recovery` scenario adds a capture with a 250-line `capture.log` and two residue items, and a Flash with an unknown outcome superseded by a recovery epoch. |
| Strings | 10 `JobsLocalizable` keys, values unchanged. |

Delegated minor decisions (pending the next rulings batch):

1. **Log roles are a table checked against the Catalog**, as Diagnostics' Artifact roles (ruling 75):
   the Windows App has no Catalog descriptor.
2. **Read log is never disabled**: for a sensitive log it says that only standard logs are read here.

## Checks on the reference host

Local targeted checks (2026-10-04, on `ea0036f0`; logs in the session scratchpad `x3/inspector-full.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive; SHA-256 `3ee1a7bb571ff107f1ec76bb519a22121f3140616a35fa7f698f1b2915c9ae6f`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 153 passed (JobInspectorTests 3) |
| ClientKit.Tests | 42 passed, 1 skipped (needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, the daemon above) | 122 passed, 1 skipped (needs an installed package), 1 failed: one jobs-scenario snapshot timed out in a UIA Select under host load (another teammate's runs); the 20 snapshot cases then passed twice in a row. JobInspectorFlowTests passes. |
| the four generators `--check` | exit 0 |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

CI: to be recorded by the PR's hosted run; not verified here.
