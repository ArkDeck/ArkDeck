# TASK-XPA-020 — WinUI Flash workspace at macOS parity, 2026-10-01

- Task: TASK-XPA-020, WM5 (`docs/design/cross-platform/windows-phase-agent-prompt.md`), the second
  of the remaining surface PRs (Debug #2430; this, Flash; then Viewer with TASK-XPA-021's Trace,
  and Diagnostics). The lead's instruction: full macOS parity over the scripted transport, and
  the real daemon's refusal shown as it is wherever the Windows daemon cannot serve yet. The
  proposed maintainer ruling "macOS logic is the standard" is on hold, so nothing here relies on it.
- Base: branch `agent/xpa-020-winui-flash-20261001`, one commit on `origin/main` `7db4c2c5`
  (#2433's Windows ArkForge composition included); nothing is force-pushed.
- Host: the Windows 11 x64 reference host, non-elevated; .NET SDK 10.0.401, Windows App SDK 2.5.1,
  MSTest 4.4.1, FlaUI.UIA3 5.0.0; `ARKDECK_DEV_SIGNER_THUMBPRINT` exported in the gate. No system
  setting changed; no package registered; no device, `hdc`, `arkforged` or DAYU200. Only the App
  instances and daemon copies the tests and probes launched ran; none was left running.

Host evidence for the client, not device, platform or Narrator-by-ear acceptance. No partition
was written and no destructive Job was admitted on a real Runtime.

## The macOS surface

`ArkDeckApp/Features/Flash/FlashWorkspaceView.swift` (1,891 lines),
`FlashRuntimeActivityView.swift` (401 lines) and their facade and host review in `ArkDeckKit`,
read in full. The page: the current device and its readiness, one primary surface (choose an
image; the one fully named Flash button with its user-data impact; the running progress; the
result with its postflight checks; recovery) and a details disclosure (availability, device
access, bootloader, profile and Target, prerequisites, the exact plan and the Runtime activity).
The calls: `operation.list|describe` (`flash.full-restore@1`), `target.list`, `job.list`,
`flash.device-access`, `flash.bootloader-status`, `flash.prerequisites`,
`flash.lanePlanPreview`, `flash.bind-current-loader`, `artifact.import.*` (the archive as a
`flash-bundle` for its lease), `job.plan`, `job.submit` (as reviewed), `job.show`/`job.run`
and `job.evidence`.

## What was built

| Part | Content |
| --- | --- |
| `App.Core/Presentation/FlashArchive.cs` | The host archive review macOS runs before anything is sent: the gzip/tar reader and its selection policy (suffixes or magic), the DAYU200 derivation (partitions in write order, member names, sizes and SHA-256, write-forbidden members, prerequisites, the build version, the user-data impact) and the import policy; failures classified as the macOS facade classifies them. `FlashArchiveTests` replays all 41 cases of the Swift oracle corpus (`rust/tests/fixtures/flash-archive`). |
| `App.Core/Catalog/flash-catalog-review.json` | The catalog review macOS compiles in (`FlashReviewCatalogGenerated.swift`): the step set, its digest and effects. Embedded; `TheCatalogReviewIsTheOneTheMacOsAppCompilesIn` fails on drift. |
| `App.Core/Presentation/Flash.cs` | The workspace load; the preparation (review → `flash.prerequisites` → Import as `images.tar.gz` → `job.plan` of the typed request, checked to be exactly that request on that Target and binding, plan only, with the catalog's steps); the lane plan preview; the loader bind; submit as reviewed; the running status and the macOS progress projector (byte-weighted partition writes); the terminal Job and its evidence (observed firmware and binding revision for the postflight). `RuntimeJobs.ShowAsync` is shared with Debug. |
| `App/Pages/FlashPage.cs` | The page as above; details is a toggle button (below). The submit flow binds the current loader first when the plan asks, re-prepares, submits, follows the status every 500 ms to the terminal, reads the evidence and shows the postflight rows (build, binding: match or mismatch). |
| Strings | All 208 `FlashLocalizable` keys (values unchanged; the table joins the generator's inputs and the windows lane's) and 6 Windows-only. |
| Scripted transport | `ScriptedDaemon.Flash.cs`, scenario `flash`, over `Testing/Recorded/flash-workspace.json` (the flash host facts oracle, the flash-run oracle's canonical run and the ControlFrames device-access corpus, re-keyed to the fixture Target): a daemon with the ArkForge lane and its validator. The `jobs` scenario keeps the Windows daemon's measured answers: its flash-bundle validator (the host import policy) refuses content that is not a DAYU200 images archive, and its `job.plan` of a Flash refuses with the lane's absence. |

Windows lane inputs: `scripts/ci/plan.py` adds the flash-archive corpus and
`FlashReviewCatalogGenerated.swift`, which the App's tests read, so an edit to either runs the
windows lane (`test_plan` declares both).

Delegated minor decisions (pending the next rulings batch):

1. **The host review is ported to C#.** macOS reviews the archive in the App before sending it;
   parity needs the same facts before the Runtime is asked. The port is checked against every
   Swift oracle case, not re-derived.
2. **The catalog review is embedded** from the Swift-generated catalog, with a drift test, instead
   of asked of the Runtime (macOS compiles it in).
3. **Windows wording for three macOS strings** that name the Mac (`windows.flash.action.power`,
   `windows.flash.progress.keepConnected`, `windows.flash.runtime.criticalWrite`: "the PC"), plus
   two Windows-only lines where macOS uses an alert (`windows.flash.chooseImage.invalid`,
   `windows.flash.targetChanged`) and the navigation label.
4. **Details is a plain toggle button** (`flash.workspace.details`, its name flipping to Hide
   details), as the macOS view's button, not an Expander: an Expander's collapsed content is not
   in the UIA tree, and naming both the Expander and its header duplicated the Tab stop.
5. **`flash.bind-current-loader` is allowed** in `ShellContractTests.TheAppHoldsNoRuntimeSemantics`
   beside `job.plan|submit|run`: macOS binds the current loader from the workspace when the plan
   asks for it.
6. **The scripted `flash` scenario** answers from the recorded Swift oracles, as Debug's does; it
   is the only place a Flash reaches its terminal state in these tests.

## What the real daemon answers (measured, `main` `f41eb0c9`, daemon SHA-256 `25dab410…5496`)

Over a development root with the recorded adopted Target (`TGT-3ba3f5f43b92`, binding 1), no
`ARKDECK_ARKFORGE_BUNDLE_PATH`: the start reports `no ArkForge lane`; `operation.list` lists
`flash.full-restore@1` (and `flash.dayu200`) `unavailable`, `provider arkforge is not registered`;
`flash.device-access` answers `rejected`, "Rockchip device access observation failed";
`flash.bootloader-status` `rejected` (the USB registry is unavailable until the DAYU200 mapping is
confirmed); `flash.prerequisites` `rejected` (no native RockUSB lane); `flash.lanePlanPreview`
`laneNotComposed`; `flash.bind-current-loader` `internalError`, "Rockchip Loader binding is not
configured". A flash-bundle Import of 4,096 zero bytes is refused at commit, `invalidInput`,
"Import content failed its registered format validator" (`importOwner`, no dispatch); the real
`complete.tar.gz` passes the validator and is committed, and its `job.plan` is refused
`invalidInput`, "flash.full-restore@1 is runtime unavailable: no ArkForge lane: …", before
admission. `job.list` stays empty.

#2433 changed two answers the Windows tests had recorded before it: the flash-bundle Import is no
longer refused as unvalidated (the Imports real-daemon test and `AgentImportFlowTests` now expect
the format validator's refusal of a non-archive), and the scripted `jobs` scenario follows.

## Accessibility

- Tab walk: the Flash page joins the pages whose every action must be a Tab stop in reading
  order, retraced by Shift+Tab. The focus walk's file is now read once the App has closed it (a
  run failed reading it while it was still being written).
- Access key Alt+F (Flash), unique with O, D, H, N, A, I, B, S.
- 225 % text: the page with its details over the `flash` daemon and the foundation's refusals.
- UIA snapshots: `flash.flash`, `flash.flash.details` (after invoking details) and
  `flash.foundation`; both languages.

## Checks on the reference host

| Check | Result |
| --- | --- |
| generator `--check` ×4 | exit 0 (ClientKit 105 methods; 885 strings: 635 shared, 250 Windows-only; tokens; 23 icon assets) |
| `dotnet build windows/ArkDeck.Windows.slnx -c Release` | exit 0, 0 warnings |
| `dotnet test` (default lane) | App.Tests 82, ClientKit.Tests 41 (2 skipped), App.UITests 81 skipped (the lane default) |
| `dotnet test` with `ARKDECK_APP_UITESTS=1`, `ARKDECK_DEV_SIGNER_THUMBPRINT` exported and the daemon of this tree | App.Tests 82, ClientKit.Tests 42 (1 skipped: `ARealArtifactSigningPublisherIsMatchedThroughWinVerifyTrust`, a real signing publisher), App.UITests 79 passed, 2 inconclusive (`KeyboardFocusIsVisible`: workstation locked; `TheInstalledAppConnectsToTheDaemonTheCliStarted`: runs only under `package-rc.ps1 -Smoke`); the eight real-daemon tests ran, none skipped; after rebasing onto `main` `7db4c2c5` (#2423) the eight again 8/8 with its daemon (SHA-256 `993a8034…4fca6`) |
| `PYTHONUTF8=1 python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check` | 0 errors, 0 warnings; clean |

Flows (`FlashFlowTests`): over the `flash` daemon, the corpus's `complete.tar.gz` chosen in the
system file dialog is reviewed, planned (plan digest `9ddf6256…4f04`, step-set digest
`c1ab01f8…0b12`, build `OpenHarmony-7.0.0.36`), flashed with the one fully named button and ends
"Flash succeeded" with both postflight checks matching; over the `jobs` daemon the same archive is
imported and its plan refused with the lane's absence, and no button is offered.

Real daemon (`RealDaemonTests.TheFlashPageShowsTheRuntimesRefusalWithoutTheLane`, ran, not
skipped): the page shows readiness Blocked with `provider arkforge is not registered`, the
Target's binding, availability Unavailable and the device access refusal; the chosen archive is
reviewed on the host and imported (the Runtime lists one committed `flash-bundle`), its plan is
refused with the lane's absence, no Flash button is offered, and no Job was admitted.

## Not done here, and why

1. **A Flash on the real daemon**: the Windows daemon composes the ArkForge lane only up to the
   HDC gate (#2433); the managed HDC waits for the Windows HDC tuple (CHG-2026-078), then AF-W1
   and the maintainer's HardwareCampaign window. The page shows the refusal.
2. **Narrator by ear, real key strokes, the system high-contrast themes and 225 % text**: as in
   `winui-settings-a11y-run.md`.
3. The 6 new Windows-only strings' Chinese values want the maintainer's review.

CI: to be recorded by the PR's hosted run; not verified here.
