# TASK-XPA-020 — WinUI Overview HDC environment and device capability matrix, 2026-10-05

- Task: the rest of sweep item 4 of `winui-history-handoff-run.md`: macOS `HDCStatusView` over
  `HDCClientDiagnosticsDecoding` and `OverviewCapabilityProductionProvider`. Base: `e5e661b1d` (the #2550 head),
  one commit stacked on `agent/xpa-020-winui-overview-next-step-20261005` (#2550). Host and
  boundaries as the earlier WinUI runs; no device, `hdc` or DAYU200.

## What was built

| Part | Content |
| --- | --- |
| `App.Core/Presentation/HdcEnvironment.cs` | `HdcEnvironment`: `runtime.hdc.status` decoded as macOS does (schema `arkdeck.runtime-hdc-status/1`, available, a 64-hex executable digest, a `127.0.0.1:<port>` endpoint, a canonical positive generation, known ownership, health and endpoint source; otherwise unavailable with its reason) and the device authorization from the current observations. `CapabilityMatrix`: the device in scope only (none online, or several and none chosen, keeps only the Catalog's Flash row and says why), hitrace and bytrace from `trace.probe` for that Target and binding, the canonical Flash row from `operation.list`, and the hidumper row from a read-only `debug.template@1` window inventory. |
| Loader | Overview also reads `runtime.hdc.status`, `operation.list` and, for the device in scope, `trace.probe`. |
| `OverviewPage` | The Environment card: the four summary facts (`overview.status.*.value`), the disclosure (`overview.advanced.toggle`, Ctrl+Shift+D) with Server & Toolchain, Capabilities (ownership, subserver, server recovery, the matrix as a list with `overview.capabilities.<id>.state|evidence`, and Check hidumper), Selected Device & Channel, Needs Attention (device trust; server recovery is unavailable through this connection, as the macOS production provider states), and Advanced Diagnostics; then the Runtime's doctor as before. |
| Scripted transport | The `jobs` HDC status reports `arkDeckManaged`, the daemon's spelling (`managed_hdc_lifecycle.rs`); the `outage` scenario allows the two further Overview reads. |
| Strings | 53 `Localizable` keys (values unchanged) and 1 Windows-only line. |

Delegated minor decisions (pending the next rulings batch):

1. **The hidumper row is proved when asked** (Check hidumper), not on every Overview refresh as
   macOS does: each proof is a new Job in History, and Overview refreshes on every visit.
2. **The macOS fact literals stay in English** ("not exposed by Runtime", "unknown — Not reported
   by Runtime", the authorization texts, the matrix evidence), as the macOS App shows them in
   every language.
3. **No HDC selection or recovery controls**: the macOS production provider offers neither (its
   tool selection and recovery are refused or unavailable), and `runtime.tool.select` and
   `runtime.hdc.restart` stay outside the App (`ShellContractTests`).
4. **The disclosure is a button with the state in its name** rather than a chevron row; its
   sections are headings in reading order (the macOS two columns become one).

## Checks on the reference host

Local targeted checks (2026-10-05, on `e5e661b1d`; logs in the session scratchpad `x3/ovhdc-full.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive; SHA-256 `aa84265fe3003cef73328b2a31f3358b43831fcafaed56023cd36c23fa0b6893`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 170 passed |
| ClientKit.Tests | 43 passed, 1 skipped (needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, the daemon above) | 127 passed, 2 skipped (keyboard focus visual check; installed MSIX) |
| the four generators `--check` | exit 0 |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

Stacked on #2550 (`agent/xpa-020-winui-overview-next-step-20261005`); the diff against that branch is this layer only.

CI: to be recorded by the PR's hosted run; not verified here.
