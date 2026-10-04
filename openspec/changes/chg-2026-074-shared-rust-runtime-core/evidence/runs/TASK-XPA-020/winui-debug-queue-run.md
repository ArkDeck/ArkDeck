# TASK-XPA-020 — WinUI Debug folder sources and deployment queue, 2026-10-04

- Task: sweep item 5 of `winui-history-handoff-run.md`: macOS #2466
  (`NativeLibraryDirectorySource.swift`, `NativeLibraryDeploymentBatch.swift`, the Debug
  workspace's directory and queue sections). Base: branch
  `agent/xpa-020-winui-debug-queue-20261004`, one commit stacked on
  `agent/xpa-020-winui-job-recovery-20261004` (#2487, the Job recovery banner),
  per the stacked-PR rule of #2485. Host and boundaries as the earlier WinUI runs; no device, `hdc`
  or DAYU200.

## What was built

| Part | Content |
| --- | --- |
| `App.Core/Presentation/NativeLibraryQueue.cs` | `NativeLibrarySource` (a local file, from a folder or alone, or a file of a saved SSH source), `NativeLibraryDirectorySource` (1–4 folders, subfolders, hidden entries and reparse points skipped, the drive root refused, at most 500 entries and 100 libraries, each once, sorted by name; containment by path with no reparse point between), and `NativeLibraryDeploymentBatch` (1–16 libraries with different names and a valid bundle; each planned and checked against the Target, binding, bundle, name, policy and digests; reviewed; submitted and run in turn; the first failure, lost submit reply or uncertain result stops it; invalidation stops a review). |
| `App/Pages/DebugPage.Queue.cs` | Choose folder (`debug.artifacts.chooseDirectory`), the libraries found as check boxes, Add to deployment queue (`debug.artifacts.batch.add`), the queue (rows with state and Job, Remove), Validate and review (`debug.artifacts.batch.prepare`), Stop, the review sheet (`debug.artifacts.batch.review`) and Deploy reviewed queue; each item through the single-library path (a server's library fetched, checked and staged first). A new Target or bundle invalidates the review. |
| Strings | 29 `DebugLocalizable` keys, values unchanged. |

Delegated minor decisions (pending the next rulings batch):

1. **Folders are added one pick at a time** (up to four): the Windows folder picker selects one
   folder; the search runs over all chosen folders again after each pick.
2. **A drive root is refused** as macOS refuses `/`; reparse points stand for symbolic links.
3. **The macOS wording "mounted SMB" stays**: a mapped drive or UNC share chosen in the picker is
   searched as any folder; no credentials or mounts are involved.

## Checks on the reference host

Local targeted checks (2026-10-04, on `429b01d7`; logs in the session scratchpad `x3/queue-full.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive; SHA-256 `68ab64bdfd6da5b7f4af4b6f34a604bc75ebfae4d8be84b6596a91a159660a63`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 150 passed (NativeLibraryQueueTests 7) |
| ClientKit.Tests | 42 passed, 1 skipped (needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, the daemon above) | 122 passed, 1 skipped (needs an installed package); DebugQueueFlowTests queues two libraries, reviews and deploys them to verified success, then removes one |
| the four generators `--check` | exit 0 |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

## Not done here, and why

Deploying on a device needs the Windows HDC tuple (CHG-2026-078); the queue reaches the Runtime's
Import and plans as the single library does, and the scripted daemon runs them.

CI: to be recorded by the PR's hosted run; not verified here.
