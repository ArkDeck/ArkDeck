# TASK-XPA-020 — WinUI Device rows, trust steps, bounded wait, live observation and aliases, 2026-10-05

- Task: the non-HDC parts of sweep item 9 of `winui-history-handoff-run.md`: macOS
  `DeviceListViewModel`, `DeviceSidebarRow` and `DeviceDetailView`. Base: `429ad86e6` (the #2572
  head), one commit stacked on `agent/xpa-020-winui-keyboard-20261005`. Host and boundaries as the
  earlier WinUI runs; no device, `hdc` or DAYU200, and nothing on 127.0.0.1:8710. The Device screen
  workspace (screenshot, input, recording) waits for the Windows HDC tuple (CHG-2026-078).

## What was built

| Part | Content |
| --- | --- |
| `App.Core/Presentation/DeviceTrust.cs` | The bounded trust wait (macOS `boundedAuthorizationWait`: re-read `device.observations` every 5 s for at most 180 s until the device is Connected, is gone or the read fails; cancellable), the end of a finished wait's verdict when a later read shows another state (`endsTrustWaitVerdict`), the App-local name of a device not adopted yet (`normalizedDisplayName`: whitespace collapsed, 1 to 64 characters) and the row title. `DeviceCandidatesAsync` reads the observation alone. |
| `AppPreferences` | Keeps the device names beside the window icon and the last page. |
| `MainWindow` | One sidebar row per observed device under Device (`app.navigation.device.<key>`: name and state; choosing it opens that device's detail; rows of devices no longer listed leave), and the live observation: every 10 s the observation is read again (the Device page re-read when it is shown), a slow read delaying the next tick. Its timer is held, so it keeps ticking. |
| `DevicePage` | The device's detail above the list: the state, for an unauthorized device the three trust steps, Start waiting (Retry after a verdict) with the wait's deadline and verdict (`device.wait.*`), Re-check, Rename… and "Use the device's own name" for a device not adopted yet, adoption named as the CLI's, and the facts the observation carries; "Device no longer listed" when it left. List rows use the same titles. |
| Scripted transport | Scenario `trust`: the unauthorized candidate trusts this computer at the fourth observation read. Launch options `--trust-wait-fast` (2 s window, 250 ms probe, as macOS `--ui-test-device-poll-fast`) and `--live-observation-ms`, both honoured with the scripted transport only, whose runs otherwise observe no device on their own. |
| Strings | 22 `Localizable` keys (values unchanged) and 2 Windows-only lines. |

Delegated minor decisions (pending the next rulings batch):

1. **Aliases name only devices not adopted yet**: an adopted Target's name is the Runtime's
   (`target.display-name.set`, already in the App), so an alias does not follow a device into
   adoption as the macOS one does; `device.display-name.set` stays outside the App.
2. **The timed-out wait does not offer "Open Overview to restart the shared HDC server…"**: the
   Windows App offers no HDC server restart (`runtime.hdc.restart` is not an App write).
3. **The deadline is shown as a time, not a running countdown.**
4. **Scripted test runs observe devices on their own only when asked**, so the request counts the
   other scenarios rely on stay deterministic.

## Checks on the reference host

Local targeted checks (2026-10-05, on `429ad86e6`; logs in the session scratchpad `x3/device-full.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive; SHA-256 `7d899c917716b275d40c391c5c93bdc61b91d0a3d6a438c28a5444f67fd1d356`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 181 passed |
| ClientKit.Tests | 43 passed, 1 skipped (needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, the daemon above) | 135 passed, 2 skipped (keyboard focus visual check; installed MSIX) |
| the four generators `--check` | exit 0 |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

Stacked on #2572 (`agent/xpa-020-winui-keyboard-20261005`); the diff against that branch is this layer only.

CI: to be recorded by the PR's hosted run; not verified here.
