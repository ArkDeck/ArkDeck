# TASK-XPA-020 — WinUI Debug workspace at macOS parity, 2026-10-01

- Task: TASK-XPA-020, WM5 (`docs/design/cross-platform/windows-phase-agent-prompt.md`), the first
  of the remaining surface PRs (Debug; then Flash, Viewer with TASK-XPA-021's Trace, Diagnostics).
  The lead's instruction: full macOS parity over the scripted transport, and the real daemon's
  refusal shown as it is wherever the Windows daemon cannot serve yet. The proposed maintainer
  ruling "macOS logic is the standard" is on hold, so nothing here relies on it.
- Base: branch `agent/xpa-020-winui-debug-flash-trace-20260930`, one commit on `origin/main`
  `d492cfd3`; nothing is force-pushed.
- Host: the Windows 11 x64 reference host, non-elevated; .NET SDK 10.0.401, Windows App SDK 2.5.1,
  MSTest 4.4.1, FlaUI.UIA3 5.0.0; `ARKDECK_DEV_SIGNER_THUMBPRINT` exported in the gate. No system
  setting changed; no package registered; no device, `hdc` or DAYU200. Only the App instances and
  daemon copies the tests and probes launched ran; none was left running.

Host evidence for the client, not device, platform or Narrator-by-ear acceptance.

## The macOS surface

`ArkDeckApp/Features/Debug/DebugWorkspaceView.swift` (3,691 lines) and
`Packages/ArkDeckKit/Sources/ArkDeckClientKit/DebugApplicationFacade.swift` (1,673 lines), read in
full. The page: the scope line, the Target picker and its binding, five tabs (Artifacts, Logs,
Apps, Network, Commands), each with its operation's availability beside the section it gates and
the operation's recent Jobs. The facade's calls: `operation.list`, `target.list`, `job.list`
(250, newest first, no timeline), `debug.probe`, `artifact.import.*` (a HAP's packages and a
native library, each for its lease), `job.plan` (the native library, reviewed before submit),
`job.submit` (a `runtime-operation-request` 1.0.0 with a fixed operation, typed inputs, the Target
and binding revision, and the workspace's client name), `job.run`, `job.show` (and
`job.timeline` when paged) and `job.cancel`.

## What was built

| Part | Content |
| --- | --- |
| `App.Core/Presentation/RuntimeJobs.cs` | `RuntimeRequest`, the typed request as macOS builds it (canonical JSON, `clientContext` with the workspace client name and the run-grouping thread `t-` + SHA-256(salt\|client\|target)[..12], the reviewed plan digest pinned for a reviewed request); `OperationFacts` (`operation.list` availability with reasons, `operation.describe` title, effect, budgets and steps); `RecentJob` (the `arkdeck.job-summary/1` rows, the failure code or the one the state implies, as macOS's `compatibilityFailure`); `JobPlan` (plan only, not admitted, not dispatched, a SHA-256 digest); `JobTerminal` (`job.show` state, outcome and timeline, `job.timeline` pages joined). Shared by the coming Flash and Trace PRs. |
| `App.Core/Presentation/Debug.cs` | The six operation references and the workspace client names; the macOS validators (bundle, ability, native library, HiLog component, package names, port rules); `DebugProbe`; the workspace load (`DebugAsync`: operations, Targets, recent Debug Jobs and the newest six's Artifacts, the selected Target's probe); the typed actions: HiLog capture (the Debug logs preset), port rule create/remove, template, HAP (every package inspected and deduplicated by bytes before the first upload, each imported for its lease, `additionalHapArtifactLeases` only when there are some) and the native library (imported; the Import's ELF facts; planned with the ABI the Runtime observed; the plan checked to be exactly that request on that Target and binding, plan only, the HDC provider, a device mutation, the published steps; submitted as reviewed). |
| `App/Pages/DebugPage*.cs` | The page as above. Each tab's action runs as the macOS view models run it (submit, `job.run` to the end, the terminal read back, the workspace re-read). The native library's plan sheet names the Target and binding, the library, the bundle, the effect, verification, rollback, the plan digest and every step. Log shards and command reports export through the History export (preview, a sensitive Artifact's own confirmation, the save dialog, the digest-verified read). |
| Strings | All 239 `DebugLocalizable` keys (values unchanged; the table joins the generator's inputs and the windows lane's) and 9 Windows-only. |
| Scripted transport | `ScriptedDaemon.Debug.cs` over `Testing/Recorded/debug-workspace.json`: the six operations' measured `operation.describe`/`operation.list` answers (made available), the debug-probe oracle's probe, the deploy-native-library oracle's plan, and the capture-diagnostics, debug-hap, deploy-native-library and port-forward oracles' `job.run` answers. Port rules change the probe; a cancelled Job ends cancelled. |

Delegated minor decisions (pending the next rulings batch):

1. **The App submits Jobs.** macOS Debug submits its closed typed Jobs from the App through the
   facade; parity needs the same. `ShellContractTests.TheAppHoldsNoRuntimeSemantics` now allows
   `job.plan`, `job.submit` and `job.run` in the typed-request files only, and
   `TheAppSubmitsOnlyTheMacOsWorkspaceOperations` pins every operation the App can build to the
   macOS workspaces' fixed references.
2. **No disabled controls** (XPA-AC-8): where macOS disables an action (no Target, the operation
   unavailable, invalid inputs, a Job of the tab running), the action stays and its status line
   says which. The two macOS placeholders for actions no published operation runs (the HiLog
   buffer clear; per-package start, stop, uninstall) are their reason text, not disabled buttons.
3. **Remote build sources**: an App-side SSH setting (`RemoteBuildSourceApplicationFacade`, Keychain)
   the Windows App does not have. The Remote source opens the browser on its no-servers state,
   with a line saying so; local libraries work as on macOS.
4. **Local ELF pre-check**: macOS validates the signed OpenHarmony ELF in the App before the
   upload; the Runtime's Import validates it again and reports the facts, which is what Windows
   checks (the plan must carry exactly the ABI the Import reported).

## What the real daemon answers (measured, `main` `d492cfd3`, daemon SHA-256 `04cba3d4…a790`)

Over a development root with the recorded adopted Target (`TGT-3ba3f5f43b92`, binding 1):
`operation.list` lists the six operations `unavailable`, reason `provider hdc is not registered`
(`provider_not_registered`); `operation.describe` answers each; `debug.probe` answers
`internalError`, "Debug Runtime probing is not configured"; `job.plan` and `job.submit` of a
typed `capture.diagnostics@1` request answer `invalidInput`, "provider hdc is not registered",
before admission (`newDispatchCount` 0); `job.list` is an empty page. On the private-endpoint
foundation the Target owner is absent (`internalError`, "Target owner is not configured").

## Accessibility

- Tab walk: each of the five tabs joins the pages whose every action must be a Tab stop in
  reading order, retraced by Shift+Tab. Disclosures (Advanced, the typed request) are Fluent
  Expanders whose header toggle carries the identifier and name.
- Access key Alt+B (Debug), unique with O, D, H, N, A, I, S.
- Escape closes the remote build browser (and, as every ContentDialog, the plan sheet and the
  export preview).
- 225 % text: the five tabs over the scripted daemon and the foundation's refusals.
- UIA snapshots: the Artifacts tab, the Network tab with the recorded rules, the Commands tab, and
  the foundation; both languages.

## Checks on the reference host

| Check | Result |
| --- | --- |
| generator `--check` ×4 | exit 0 (ClientKit 105 methods; 671 strings: 427 shared, 244 Windows-only; tokens; 23 icon assets) |
| `dotnet build windows/ArkDeck.Windows.slnx -c Release` | exit 0, 0 warnings |
| `dotnet test` with `ARKDECK_APP_UITESTS=1`, `ARKDECK_DEV_SIGNER_THUMBPRINT` exported and the daemon of this tree | App.Tests 69, ClientKit.Tests 42 (1 skipped: `ARealArtifactSigningPublisherIsMatchedThroughWinVerifyTrust`, a real signing publisher), App.UITests 73 passed, 2 inconclusive (`KeyboardFocusIsVisible`: workstation locked; `TheInstalledAppConnectsToTheDaemonTheCliStarted`: runs only under `package-rc.ps1 -Smoke`); after merging `main` `d492cfd3` (#2426's HDC tuple gate included) the seven real-daemon tests again 7/7 |
| `PYTHONUTF8=1 python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check` | 0 errors, 0 warnings; clean |

Flows (`DebugFlowTests`, scripted): a HiLog capture with a tag filter runs to `succeeded` and
lists its Job; an invalid PID filter is named and not sent; `device.uptime` runs and its result
shows state and a known outcome; a port rule 9300→9301 is validated as typed, added, listed and
deleted; a HAP chosen in the system file dialog runs to `succeeded`; a native library chosen in
the dialog is planned, the sheet shows the recorded plan digest `600694d5…dc1a` and its steps, and
Run deploys it (`Verified`).

Real daemon (`RealDaemonTests.TheDebugPageShowsTheRuntimesRefusalWithoutHdc`, ran, not skipped):
the page shows the Target's binding, every operation `Unavailable` with `provider hdc is not
registered`, Start capture says the operation cannot run (nothing sent), the Apps inventory shows
`unavailable(internalError): Debug Runtime probing is not configured`, and a typed request sent
over the pipe is refused with `provider hdc is not registered`.

## Not done here, and why

1. **A Debug Job on the real daemon**: every Debug operation needs the Windows HDC tuple, which is
   not registered (CHG-2026-078); the page shows the refusal.
2. **Remote build sources** (decision 3).
3. **Narrator by ear, real key strokes, the system high-contrast themes and 225 % text**: as in
   `winui-settings-a11y-run.md`.
4. The 9 new Windows-only strings' Chinese values want the maintainer's review.

CI: to be recorded by the PR's hosted run; not verified here.
