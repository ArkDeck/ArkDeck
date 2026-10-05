# TASK-XPA-020 — WinUI Settings storage policy and root, and the Trace cache purge, 2026-10-05

- Task: the first part of sweep item 7 of `winui-history-handoff-run.md`: macOS
  `StorageSettingsPane` over `SettingsApplicationFacade` (`runtime.storage.policy`,
  `runtime.storage.root`) and `TraceCacheSettingsView` over
  `RuntimeTraceCacheApplicationFacade` (`trace.cache.purge`). Base: `origin/main` `efb64785d` (with #2550 and
  #2553 merged), one commit. Host and boundaries as
  the earlier WinUI runs; no device, `hdc` or DAYU200.

## What was built

| Part | Content |
| --- | --- |
| `App.Core/Presentation/Settings.cs` | `StorageStatus` carries the Session domain's generation; `StorageStatus.Draft` checks the drafts as macOS `savePolicy` does (whole GiB and days, quota above a positive margin, no overflow). The loader's `SaveStoragePolicyAsync` and `SetStorageRootAsync` (a folder, or `resetToDefault`) read `runtime.storage.status`, send the write with that `expectedGeneration`, and on `resourceConflict` read the owner's state back without re-sending (macOS `publish`); `PurgeTraceCacheAsync` checks the report as macOS `RuntimeTraceCacheResponseDecoding.purge` does (exact keys, `inactiveDerivedDatabases`, no original Trace removed). |
| `SettingsPage` | Storage: Session location (root, source, Choose folder…, Use default), Retention policy (quota, margin, retention fields, Save policy), each confirmed in a dialog that states the values or folder; the Runtime's answer (saved, superseded by another writer, or refused with its reason) in `settings.storage.status`. Trace: Purge unused entries, confirmed with the inactive count, and the Runtime's count of removed entries. |
| Scripted transport | The `jobs` storage owner keeps a generation, refuses an invalid policy or root, publishes another writer's policy first for a 99 GiB quota, and purges the one inactive derived database; its Trace cache status spells the scope `inactiveDerivedDatabases`, as the daemon does. |
| Strings | 15 `SettingsLocalizable` keys (values unchanged) and 14 Windows-only lines. |

Delegated minor decisions (pending the next rulings batch):

1. **The App submits `runtime.storage.policy`, `runtime.storage.root` and `trace.cache.purge`**
   (macOS parity: `SettingsApplicationFacade` and `RuntimeTraceCacheApplicationFacade` submit
   them). They move from the forbidden to the allowed list of `ShellContractTests`, as
   confirmed writes shaped like the Session actions: the Runtime stays the authority, the App only
   submits the request and renders the Runtime's answer, refusal or result, and decides no
   policy locally (the draft check only spares a request the Runtime would refuse).
2. **Each write is confirmed in a dialog** stating what will be sent (macOS saves on the button);
   the Runtime offers no preview method for these, so the confirmation shows the request.
3. **The default root's source reads "Local application data default"** (Windows-only line; the
   macOS value names Application Support).
4. **The ArkTrace licence view is not ported**: the Windows App ships no ArkTrace or
   TraceStreamer build (the Viewer ruling), so it has no such licences to show.

## Checks on the reference host

Local targeted checks (2026-10-05, on `efb64785d`; logs in the session scratchpad `x3/settings2-full.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive; SHA-256 `d0a33694fa1f4f45fd8554ef763575492f0f70e3f7e9ec6bc297726ca8e96439`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 174 passed |
| ClientKit.Tests | 43 passed, 1 skipped (needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, the daemon above) | 128 passed, 2 skipped (keyboard focus visual check; installed MSIX) |
| the four generators `--check` | exit 0 |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

CI: to be recorded by the PR's hosted run; not verified here.
