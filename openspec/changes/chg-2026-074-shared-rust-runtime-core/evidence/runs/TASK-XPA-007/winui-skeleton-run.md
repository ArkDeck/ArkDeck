# TASK-XPA-007 — WinUI 3 walking skeleton on the real Windows daemon, 2026-09-30

- Task: TASK-XPA-007, client lane slice X2 (WM5 of `docs/design/cross-platform/windows-phase-agent-prompt.md`):
  the product App under `windows/App/` wired to the daemon through ArkDeck.ClientKit —
  Overview, Device, History, the Job Inspector and the daemon-unavailable recovery banner —
  the shared bilingual source `spec/ui-semantics/`, UIA semantic snapshot tests, and the
  `windows` lane building and testing all of it.
- Base: stacked on the ClientKit slice (PR #2355, branch `agent/xpa-007-clientkit-20260930`,
  head `604a0f47`, itself on `main` at `84a44be1`), which is not merged yet. `main` is merged in
  after #2355 lands; nothing is force-pushed.
- Host: the Windows 11 x64 reference host (Windows 11 Pro 10.0.26200), non-elevated, .NET SDK
  10.0.401, Windows App SDK 2.5.1 (SPK-4 pins), MSTest 4.4.1, FlaUI.UIA3 5.0.0. Nothing was
  installed beyond NuGet restores into `D:\nuget\packages`; no system setting was changed; no
  package was registered; the only processes started and stopped were the App instances and
  the daemon copies the tests launched (none left running, temporary directories removed).

This is host evidence for the client skeleton. It is not platform, device or Narrator-by-ear
acceptance: the daemon under test is the read-only foundation (no HDC tuple, no Job owner),
and a scripted transport stands in for states that daemon cannot produce.

## What was built

| Path | Content |
| --- | --- |
| `spec/ui-semantics/strings.json` | The shared bilingual source (132 entries). 99 are the macOS App's entries of `Localizable`, `HistoryLocalizable` and `JobsLocalizable` `.xcstrings`, values unchanged (navigation, device states and facts, Overview Environment/Recent Work, History states and notices, Job Inspector and `job.state.*`); 33 are Windows-only `windows.*` keys for surfaces with no macOS counterpart (the daemon-unavailable recovery banner, `unavailable(%1$@): %2$@`, `CLI: %@`, Copy CLI command, the doctor summary, the test-transport banner), each with an English and a Simplified Chinese value |
| `spec/ui-semantics/surfaces.json` | UI semantic snapshots: 8 (page × daemon state) snapshots, 62 elements, each an identifier (the macOS accessibility identifier where one exists, `origin: macos`), a role, an accessible name built from catalogue keys, and the live setting where it matters |
| `windows/scripts/generate-ui-strings.py` | `--write`/`--check`: writes `windows/App/Strings/{en-US,zh-Hans}/Resources.resw` and `windows/App.Core/Generated/UiStrings.g.cs` (key constants); checks every shared entry against its `.xcstrings` value in both languages (a `--write` would change only a differing value in place, keeping the table's own formatting); refuses duplicate keys, resource-name collisions, placeholder mismatches between languages and tables not declared in `INPUTS`. Today it writes no `.xcstrings` byte: every value is already equal |
| `windows/scripts/generate-xaml-tokens.py` | The SPK-4 token generator moved to the product, output `windows/App/Themes/ArkDeckTokens.xaml`, plus **ruling 16**: the Light and Dark dictionaries redefine the Windows accent ramp (`SystemAccentColor`, `Light1..3` ← `--ad-accent`, `Dark1..3` ← `--ad-accent-fill`); HighContrast redefines no accent and maps every token to a system colour |
| `windows/App.Core/` | `ArkDeck.App.Core` (`net10.0-windows`): `DaemonConfiguration` (the CLI's installation inputs `ARKDECK_DAEMON_PATH` / `_SIGNER_SHA256` / `_PACKAGE_FAMILY` / `ARKDECK_ENDPOINT`; no pin → connect to nothing), `IControlChannel` over `ControlSession` (production) or over ClientKit's `ControlClient` on a scripted stream, `SurfaceLoader` (one ClientKit read per call, stops a refresh after the first daemon-unavailable failure), the page states, `Unavailable` (`unavailable(reasonCode): detail` + CLI command), `RecoveryBannerState`, `Localizer` (printf placeholders, visible missing keys), `AppLanguage`, `ScriptedDaemon` |
| `windows/App/` | `ArkDeck.exe`: WinUI 3, Windows App SDK 2.5.1 self-contained, x64, MSIX tooling with the development identity `CN=ArkDeck Development` (ruling 12), unsigned locally. Shell, pages and the Job Inspector described below |
| `windows/App.Tests/` | MSTest, 21 tests (below) |
| `windows/App.UITests/` | MSTest + FlaUI (UIA3), 12 tests (below); run only with `ARKDECK_APP_UITESTS=1` on a desktop session, otherwise reported skipped |
| `windows/ArkDeck.Windows.slnx`, `Directory.Packages.props`, `README.md` | Solution with the four new projects (x64 platform); SPK-4's Windows App SDK, SDK build tools and FlaUI pins |
| `scripts/ci/plan.py`, `scripts/ci/test_plan.py`, `.github/workflows/swift-ci.yml`, `scripts/test_agent_pr_workflow.py` | The `windows` lane (below) |

## Screens (described; no screenshots committed)

- **Shell.** Mica window, custom title bar "ArkDeck" with the pane toggle, NavigationView with
  the macOS sidebar grouping: header "Device"/"设备" → Overview, Device; header
  "Records"/"记录" → History (identifiers `app.navigation.overview|device|history`). Below the
  page, the global Job Inspector as on macOS. No Settings item and no placeholder item.
- **Recovery banner** (`app.recovery.daemonUnavailable`, error `InfoBar`, assertive live
  region), shown whenever a read finds the daemon unavailable and closed once the daemon answers:
  title "ArkDeck Runtime unavailable", a message per ClientKit reason (not running / not the
  installed Runtime / another contract / no identity configured), the remedy, "Reason:
  `<DaemonUnavailableReason>`: `<ClientKit message>`", "CLI: arkdeck doctor" with Copy CLI
  command, and Retry (re-reads the page and the inspector). The App does not start the daemon.
- **Overview.** Title, Refresh. Card "Environment": "Overall: Blocked", "6 blockers · 2
  warnings · 2 info", protocol version, contract identity, "Available operations 0 of 30",
  "Needs Attention" and the list of the daemon's findings ("Blocker: the Runtime has no
  registered provider (provider.noneRegistered)", …), or "Runtime diagnostics could not be
  read" + reason + CLI. Card "Recent Work": the last five Jobs with the macOS run chips, or
  "Runtime history could not be read" + `unavailable(rejected): The Job owner is not configured`
  + "CLI: arkdeck job list" + Copy.
- **Device.** Title, "Refresh Devices". With candidates: one row per candidate, its title
  (display name, device name or connect key), the macOS state name (Ready / Authorized · not
  adopted / Needs trust / Offline / Status needs re-check, raw state otherwise) and the facts
  the daemon reported. Today: "Device list unavailable", `unavailable(rejected):
  hdc.notConfigured`, "CLI: arkdeck device candidates", Copy, Re-check. Always the macOS note
  that adoption is done in the CLI.
- **History.** Title, "Refresh history". The Jobs (`history.row.<jobId>`, state by
  `history.state.*` plus " · outcome unknown"); choosing one opens it in the Job Inspector.
  Today: "Runtime History Unavailable", the reason, "Start or reconnect ArkDeck Runtime, then
  refresh the history.", CLI and Copy. The read-only note.
- **Job Inspector.** Bar: Hide/Show job inspector, Refresh jobs, Open History, and a polite
  live-region status ("Runtime status unavailable" / "No Runtime jobs" / "%d active"). Expanded:
  the Jobs (attention first, then active, then the rest, by `job.state.*` names) or "Runtime
  status unavailable" + reason + guidance + CLI; the selected Job's Runtime facts (state as an
  assertive live region, attention text for outcome unknown / waiting for human, Job,
  Operation, Target, Recorded state, Execution mode) and its observed timeline from
  `job.events`. While the Job is active it is re-read every 2 s and a state change is
  announced. No Job action (cancel, retry, submit) exists in this slice, so none is shown.

No control is ever disabled (XPA-AC-8): an action this slice does not have is absent, and a
read without data shows `unavailable(reasonCode)` and its CLI command with a working copy
action. Every visible string comes from the catalogue; the language is set explicitly at start
(`--language`, else the first supported Windows language, else English) through
`ApplicationLanguages.PrimaryLanguageOverride` and an explicit MRT resource context.

## Checks on the reference host

| Check | Result |
| --- | --- |
| `python windows/scripts/generate-clientkit.py --check` | exit 0 (105 methods) |
| `python windows/scripts/generate-ui-strings.py --check` | exit 0: 132 strings, 99 shared with the macOS App (values unchanged), 33 Windows-only |
| `python windows/scripts/generate-xaml-tokens.py --check` | exit 0 |
| `dotnet build windows/ArkDeck.Windows.slnx -c Release` | exit 0, 0 warnings, 0 errors (warnings are errors) |
| `dotnet test windows/ArkDeck.Windows.slnx -c Release --no-build` (lane default) | exit 0: App.Tests 21 passed; ClientKit.Tests 31 passed, 1 skipped (end-to-end, no daemon given); App.UITests 12 skipped |
| same with `ARKDECK_APP_UITESTS=1` and `ARKDECK_CLIENTKIT_DAEMON` = a `cargo build -p arkdeck-agentd --locked` daemon (SHA-256 `965bdcaf…c0bd`, the bytes the ClientKit record used) | exit 0: 65 passed, 0 skipped (App.Tests 21, ClientKit.Tests 32, App.UITests 12) |
| `PYTHONUTF8=1 "$ARKDECK_PYTHON" -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK (49 + 17) |
| `sh scripts/check-sdd.sh`, `git diff --check` | see the PR |

**App.Tests (21):** generator drift of the strings and the tokens (run from the test); every
catalogue key in both `.resw` with the source values; every shared entry equal to its `.xcstrings`
value read directly (independent of the generator); missing keys visible and recorded; printf
placeholders (positional, `%lld`, `%%`); language resolution; long strings wrap; each scripted
scenario through ClientKit → page states (nothing answering → banner "not running", no data;
another contract → contract banner; today's daemon → blocked doctor, `unavailable(rejected):
hdc.notConfigured`, `unavailable(rejected): The Job owner is not configured`; candidates → the
macOS state names; a running Job advancing through four states with a timeline ending at the
current state; an unknown Job → `unavailable(notFound)`); no identity or an invalid endpoint →
nothing connected, "no identity" banner; no `IsEnabled=false` anywhere; no literal colour; the
product accent in Light/Dark and none in HighContrast; no Job/target write method named and no
pipe code in the App; every CLI command is a `cli-feature-coverage.json` target or equivalent
command; the terminal Job states equal `spec/recovery/job-state-preflight.json`; every snapshot
names known keys, roles and scenarios.

**App.UITests (12), on this host:**

1. `PagesMatchTheirSemanticSnapshots` × {foundation, unavailable, contract-mismatch, jobs} ×
   {en-US, zh-Hans}: 124 element observations (8 snapshots of 62 elements, in both languages), every identifier
   found with the expected UIA role, name and live setting, and no disabled button in the
   window. Example (zh-Hans): `app.devices.unavailable.reason` Text
   "unavailable(rejected)：hdc.notConfigured"; `history.unavailable.title` Text "无法读取 Runtime 历史";
   `jobInspector.toggle` Button "收起 Job 检查器".
2. `TheRecoveryBannerIsAnnouncedWhenTheDaemonGoesAway`: data shown, then the daemon stops
   answering; Refresh → the banner opens (assertive) and a `LiveRegionChanged` event comes from
   `app.recovery.daemonUnavailable`; the doctor card shows `unavailable(daemonUnavailable)`.
3. `TheRecoveryBannerGoesAwayAfterRetry`: nothing answers at start → banner; Retry after the
   daemon answers → the page shows the daemon's refusal and the banner closes.
4. `JobStateChangesReachTheLiveRegion`: selecting the running Job in the inspector; the
   assertive `jobInspector.state` raised `LiveRegionChanged` with "Waiting for device" and
   "Succeeded" as the Job advanced; no Job action is offered.
5. `TheAppShowsTheDevSignedDaemonAndItsAbsence` — the real daemon: the daemon copy signed with
   the host-trusted development certificate (`rust/scripts/windows-dev-identity.ps1 sign`, as the
   ClientKit end-to-end test does), started on a private endpoint; the App given only
   `ARKDECK_ENDPOINT`, `ARKDECK_DAEMON_PATH` and `ARKDECK_DAEMON_SIGNER_SHA256`. Observed:
   Overview "Overall: Blocked / 6 blockers · 2 warnings · 2 info", protocol 1.0.0, no banner;
   Device `unavailable(rejected): hdc.notConfigured`; History `unavailable(rejected): The Job
   owner is not configured`; no disabled button. After the daemon was killed, History's
   Refresh → the banner and `unavailable(daemonUnavailable): the local Runtime endpoint is
   unavailable: … (Win32 error 2)`, reason `EndpointUnavailable`.

The UIA runs used the interactive session through UIA patterns (Invoke, SelectionItem) only; no
synthetic input.

## `windows` lane

`classify_paths` now also selects `windows` for `spec/ui-semantics/**`, the three `.xcstrings`
tables the catalogue shares, `docs/design/arkdeck-ds/src/tokens.css`,
`spec/recovery/job-state-preflight.json` and `openspec/contracts/cli-feature-coverage.json`
(the tests read them). `test_plan.py` loads the `INPUTS` of all three generators and asserts each
input (and a new file in each input directory) selects the lane, checks that unrelated design
and catalogue files do not, and that `--run-local` runs the three generator checks before the
build and the test. The hosted job `windows-clientkit` runs the same five commands (timeout
raised to 30 minutes for the Windows App SDK restore); `test_agent_pr_workflow.py` pins the two
new steps, their order, and two new mutation cases. **Local-only:** the UIA tests of the running
App and the real-daemon tests (they need a desktop session, the development signer and a built
daemon); the hosted job builds them and reports them skipped.

## Limits and what is deferred

1. **No macOS AX snapshot was recorded for comparison.** `surfaces.json` names the macOS
   identifier for 26 of its 62 elements (`origin: macos`), taken from the SwiftUI sources; a
   side-by-side run against the macOS App's accessibility tree (XPA-AC-8's "semantically equal
   to the macOS AX snapshot") needs the macOS UI test lane and is not claimed here.
2. **Narrator by ear, keyboard path, high contrast and 225 % text** were not exercised (SPK-4's
   maintainer list still applies). The accent (ruling 16) is checked in the generated
   dictionaries, not by pixel.
3. **The macOS `.xcstrings` are not yet generated from `spec/ui-semantics`**: the generator
   checks (and would update) the 99 shared values in place; turning the three tables into fully
   generated files is a later step that changes no value.
4. **The daemon's identity** comes from environment variables (the CLI's installation inputs).
   The packaged App finding its packaged daemon (package family, ruling 8) is TASK-XPA-022; the
   App does not start the daemon (decision 11's client start is the CLI's; the banner names
   `arkdeck doctor`).
5. **Windows-only strings.** The recovery banner, the doctor summary and the
   `unavailable(...)`/CLI lines have no macOS keys (macOS shows per-surface unavailable states);
   their Chinese values are new and want the maintainer's review.
6. **The scripted test transport ships in the App** behind `--test-transport` and always shows
   the "Test transport" banner; it replaces only the pipe (ClientKit still decodes and
   schema-checks every reply).
7. **Two surfaces show a raw state name** where the macOS catalogue has none
   (`recovered`, `recoveringByCompleteOverwrite`), as the macOS App does.
8. `openspec/contracts/cli-feature-coverage.json` still has no Windows status for the `app.*`
   entries these surfaces cover (ruling 10 reviews that list at WM6).
9. Windows App SDK AI components are still in the self-contained output (SPK-4 finding; trimming
   the package set is TASK-XPA-022); the Release build no longer trims at build time (only on
   publish, where IL2104 from `Microsoft.Windows.SDK.NET`/`WinRT.Runtime` is suppressed).

CI: to be recorded by the PR's hosted run (`windows-clientkit`, `swift` aggregate); not verified here.
