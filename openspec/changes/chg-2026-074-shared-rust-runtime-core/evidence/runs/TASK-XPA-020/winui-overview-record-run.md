# TASK-XPA-020 — WinUI Overview next step, run threads, Run It Again and the prepared continuation, 2026-10-05

- Task: the first part of sweep item 4 of `winui-history-handoff-run.md`: macOS
  `OverviewRecordView`'s next step and run threads, `OverviewResumeSheet` and
  `WorkspaceContinuationCard`, over `OverviewRunRecordProjection` and
  `RuntimeWorkspaceContinuation`. Base: `origin/main` `1ca50d80c`, one commit. Host and
  boundaries as the earlier WinUI runs; no device, `hdc` or DAYU200. The HDC environment block
  (its capability matrix needs an HDC) is the next layer.

## What was built

| Part | Content |
| --- | --- |
| `App.Core/Presentation/OverviewRuns.cs` | `OverviewRuns`: lines of work by thread (an unthreaded run is its own line), those needing a person first, then the most recent, truncated by whole lines to four; the featured run (the latest unresolved, else the latest) and at most three others; `ResumeDisposition` with every refusal named (an unknown outcome is never replayed; only `readOnly` and `hostOnly` repeat without the workspace's gate; unread or unreported inputs are not guessed); the record view's workspace title. `WorkspaceContinuation`: the closed scope (`observe.device@1`, `capture.diagnostics@1`), the same Target and binding, scalar typed inputs, no marker times; a fresh request through `RuntimeRequest.Build` with `arkdeck.continuedFromJob` and the recorded thread as provenance. |
| Loader (`RuntimeJobs.cs`, `Surfaces.cs`) | Overview reads the record as the macOS workspaces do (`job.list`, 250, no timeline), then `job.evidence` for each shown run. `SubmitContinuationAsync`: `target.list` (exactly one Target, the recorded binding), `job.status` (unchanged, terminal, known outcome), `job.evidence` (the draft prepared again is identical), `job.plan` (the Runtime's plan of the new request is read-only for the same operation and binding), then `job.submit`, refusing a deduplicated or reused Job. `RunContinuationAsync`: `job.run` and `job.show`, the same Target and operation and a known outcome. `JobSummary` carries the thread, effect and start time. |
| `OverviewPage` | macOS order: scope, Next step (`overview.record.next.*`), Recent Work as line cards (`overview.record.thread.<id>`, Show more), each run with its effect, outcome, Run it again / Run it again… / its refusal, and View in History; then the environment. Run It Again (`overview.resume.*`) in place above the record: the source, thread, Target, effect, Catalog digest, drift notices, the parameters or why there are none, Cancel, Open Workspace, Prepare inputs. |
| Shell | `ContinuationCard` (`overview.continuation.*`) above the workspace the draft belongs to, until discarded: the inputs, the thread, Start new read-only Job once, Open new Job, the outcome. |
| Scripted transport | Scenario `continue`: a two-run `observe.device@1` thread with typed inputs, a failed destructive Flash, an unknown-outcome capture, a Trace capture without typed inputs; `job.plan` (read-only), `job.submit` and `job.run` of the continuation. |
| Strings | 56 `Localizable` keys (values unchanged) and 4 Windows-only lines. |

Delegated minor decisions (pending the next rulings batch):

1. **Run It Again is a card above the record, not a modal sheet**; it takes focus when shown
   and Cancel removes it.
2. **The Catalog check of a prepared draft is the Runtime's own `job.plan`** (read-only, same
   operation and binding, no admission blocker) instead of macOS's bundled Catalog descriptor,
   which the Windows App does not carry; the draft itself still requires scalar typed inputs.
3. **`observe.device` joins the operations the App may submit** (`ShellContractTests`), as macOS
   `RuntimeWorkspaceContinuation` does; nothing else of the continuation widens.
4. **Evidence is read for the shown runs only** (each line's featured run and its three others),
   not every run of a shown line.
5. **Buttons stay enabled (XPA-AC-8)**: where macOS disables Open Workspace, Prepare inputs or a
   second Start, the refusal is said in a status line; a run whose evidence could not be read
   opens the card, which says its inputs were not reported.

## Checks on the reference host

Local targeted checks (2026-10-05, on `1ca50d80c`; logs in the session scratchpad `x3/ovnext-full.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive; SHA-256 `36430ca982c0e007a7f269519aabb06907828d4edf5001ace92df1b88c1bb314`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 166 passed |
| ClientKit.Tests | 43 passed, 1 skipped (needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, the daemon above) | 126 passed, 2 skipped (keyboard focus visual check; installed MSIX) |
| the four generators `--check` | exit 0 |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

CI: to be recorded by the PR's hosted run; not verified here.
