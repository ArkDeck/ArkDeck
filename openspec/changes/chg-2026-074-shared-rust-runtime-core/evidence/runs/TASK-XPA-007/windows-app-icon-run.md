# TASK-XPA-007 — the Windows App's icon is the macOS AppIcon, 2026-09-30

- Task: TASK-XPA-007 (the WinUI skeleton's icon and MSIX visual assets), the maintainer's request
  relayed by the lead: the Windows App shows the macOS App's icon.
- Base: branch `agent/xpa-007-windows-app-icon-20260930`, one commit on `origin/main`.
- Host: the Windows 11 x64 reference host, non-elevated; .NET SDK 10.0.401, Windows App SDK 2.5.1.
  No system setting changed, no MSIX registered, no device or `hdc`.

## What changed

- `windows/scripts/generate-app-icons.py` (standard library only: its own PNG decoder and
  encoder over `zlib`) generates, from `ArkDeckApp/Resources/Assets.xcassets/AppIcon.appiconset`
  (Contents.json maps each PNG to size x scale, 16–1024 px):
  - `windows/App/Assets/AppIcon.ico`: 16, 20, 24, 32, 40, 48, 64 and 256 px PNG entries (the
    executable's icon, the window and title-bar icon, the taskbar icon of the unpackaged App);
  - the MSIX visual assets `Package.appxmanifest` names, each at scale-100 and scale-200:
    `Square44x44Logo` (with `targetsize-16/24/32/48/256`, plated and `altform-unplated`),
    `Square150x150Logo`, `Wide310x150Logo`, `StoreLogo`, `SplashScreen`, `LockScreenLogo`.
  Nothing is drawn. A square asset is the icon itself; the 150x150 tile, the wide tile and the
  splash screen carry it at two thirds of their height, centred on transparency. Resampling is an
  exact area average in premultiplied alpha over the smallest macOS rendition at least four times
  the target (the rendition itself when its size matches). `--check` compares decoded pixels and
  the ICO's entries, so another zlib cannot fail it.
- The previous placeholder assets are replaced; `StoreLogo.png` and
  `Square44x44Logo.targetsize-48_altform-lightunplated.png` are gone (the manifest's `StoreLogo.png`
  resolves to the scale-qualified files).
- `ArkDeck.App.csproj` packages `Assets\*.png`, and copies `AppIcon.ico` beside the unpackaged
  executable: before, the build output had no `Assets` folder, so `AppWindow.SetIcon` and the
  title bar's `ImageIconSource` found nothing in the unpackaged App and the xcopy package.
- CI: the windows lane runs `generate-app-icons.py --check` after the other generators
  (`scripts/ci/plan.py`, `.github/workflows/swift-ci.yml`, their tests in `scripts/ci/test_plan.py`
  and `scripts/test_agent_pr_workflow.py`); the iconset is a windows-lane input.

## Checks on the reference host

| Check | Result |
| --- | --- |
| `python windows/scripts/generate-app-icons.py --check` | ok: 23 assets |
| generator `--check` ×3 (ClientKit, strings, tokens) | exit 0 |
| `dotnet build windows/ArkDeck.Windows.slnx -c Release` | exit 0, 0 warnings; `Assets\AppIcon.ico` in the output |
| `dotnet test` (lane default) | App.Tests 49 passed; ClientKit.Tests 32 passed, 1 skipped (end-to-end needs the daemon) |
| `PYTHONUTF8=1 python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK (67) |
| `windows/scripts/package-rc.ps1 -SigningMode development` | exit 0: `arkdeck-rc-0.1.0-windows-x64-9f281ec0a337.zip` (built from this branch's commit before this record was completed; same product tree) (SHA-256 `e2cfa0bf…4c7f`), signer `a63546a5…0191`; the MSIX (unsigned, `69f58def…b939`) carries every asset above and `resources.pri` |
| `dotnet test` App.UITests `EveryActionIsATabStopInReadingOrder` and `SemanticSnapshotTests` (`ARKDECK_APP_UITESTS=1`) | 21 passed (the focus walk's rewritten JSON read by every page's Tab walk) |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check` | 0 errors, 0 warnings; clean |

Found on the way: `package-rc.ps1` failed at the trimmed publish of the App on `main`
(`IL2026` in `Controls/FocusWalk.cs`, the keyboard tests' focus walk added in #2383, which
serialized an anonymous type by reflection). The walk now writes its JSON with `Utf8JsonWriter`
(same fields), and the trimmed publish and the MSIX build succeed.

For the maintainer to look at (the lead's request), the development RC above was installed on the
Desktop, not registered: the xcopy form extracted to `C:\Users\fuhan\Desktop\ArkDeck`, a
Desktop shortcut `ArkDeck.lnk` with the App's icon, `bin\arkdeck.exe doctor` run once (with
`ARKDECK_DAEMON_PATH` and the signer pin in its own environment only), which started the
installed daemon under the account root, then the App launched. A `.lnk` cannot carry the
environment the development App needs to trust the daemon (`ARKDECK_DAEMON_SIGNER_SHA256`; a
production package is trusted by its package identity instead), so the shortcut runs the
two-line `ArkDeck.cmd` beside `ArkDeck.exe` that sets it for the App's process and starts it; no
user or system environment variable was set. The App showed the installed daemon's doctor report
(overall blocked: 5 blockers, 2 warnings, 3 info; HDC not configured), protocol 1.0.0, the empty
Job store and no recovery banner.

CI: to be recorded by the PR's hosted run; not verified here.
