# TASK-XPA-020 — WinUI Sessions, Job actions and their accessibility, 2026-09-30

- Task: TASK-XPA-020, client lane slice X3c (WM5 of `docs/design/cross-platform/windows-phase-agent-prompt.md`):
  the Windows client over the Job and Session owners of the Windows daemon.
- Base: branch `agent/xpa-020-winui-sessions-jobs-20260930`, cut from `origin/main` `ed5340a8`;
  written with the Settings/accessibility branch (#2383) and M1's consolidated Job/Session
  runtime branch (#2385, `4db744ca`) merged in. Both merged before the first push, so the slice
  is one commit on `main` `c7fa14cb`; nothing is force-pushed.
- Host: the Windows 11 x64 reference host, non-elevated; .NET SDK 10.0.401, Windows App SDK 2.5.1,
  MSTest 4.4.1, FlaUI.UIA3 5.0.0; `ARKDECK_DEV_SIGNER_THUMBPRINT` exported in the gate. No system
  setting changed; no package registered; no device, `hdc` or DAYU200. Only the App instances and
  daemon copies the tests launched ran; none was left running.

Host evidence for the client, not device, platform or Narrator-by-ear acceptance.

## What the daemon answers (measured)

The daemon built from this branch (M1's #2385 merged in; `cargo build -p arkdeck-agentd --locked`,
SHA-256 `1913bed8…6748`), over a development root whose owner-only `sessions` directory (created
by a first start) received a copy of the recorded Swift observe.device@1 Sessions
(`rust/tests/fixtures/observe-device/sessions`):

| Method | Answer |
| --- | --- |
| `runtime.storage.status` | the Session root, policy 90 days / 20 GiB / 2 GiB margin, 2 Sessions, 20 599 bytes; the Artifact domain (`refuseNewWorkNeverEvict`, 8 GiB) |
| `session.list`, `show` | both Sessions (13 586 and 7 013 bytes), generation 2 |
| `session.pin` | generation 3; the same generation again: `resourceConflict`, "Session catalog generation changed" (`sessionOwner`) |
| `session.export.preview` / `apply` | the destination proved `absent` on its volume, `redact`, sensitive Artifacts excluded by default; the apply writes the export where previewed |
| `runtime.storage.policy` then `session.cleanup.preview` / `apply` | with a policy the Sessions exceed: reclaim the unpinned Session (`expiredQuotaPressure`, 7 013 bytes), keep the pinned one; the apply removes exactly it |
| `job.list` | an empty page (the Job store over the root) |
| `job.cancel`, `job.result`, `job.evidence` of an unknown Job | `notFound`, "unknown job …" |
| `trace.cache.status` | answered: 0 entries, purge scope `inactiveDerivedDatabases` |
| the private-endpoint foundation | `session.*`: `rejected`, "Session owner is not configured"; `runtime.storage.status`: `rejected` with phase `runtimeStorageOwner`; `job.cancel|result|evidence`: `rejected` |

A queued Job's cancellation and a terminal Job's result need Jobs admitted in process (M1's tests
do that with the recorded Target and a dispatcher that must not be called); a plain copy of the
recorded Job store is not a store the daemon reads, so no real Job was cancelled from the App here.
The recorded Swift `job.result`/`job.evidence` answers of those Jobs
(`rust/tests/fixtures/observe-device/cases.json`, 3 results and 4 evidence answers) are read by
the App's parsers in App.Tests.

## What was built

| Surface | Content |
| --- | --- |
| Sessions (Records section, Alt+N) | the catalog (every `session.list` page); a Session's facts; Pin/Unpin by generation; Export… (a new folder inside the one the person picks with the Windows App SDK `FolderPicker`; the Runtime's preview — destination, size, device-identifier policy, the Artifacts and what happens to each — confirmed in a dialog, then `session.export.apply` with the preview's id and digest; the Runtime writes); Clean up… (`session.cleanup.preview`, the Sessions it would remove with their reason and size, confirmed in a dialog, then `apply` with that preview's id and digest; "nothing to clean up" when the policy keeps everything); results in a polite live region |
| Job Inspector | Open this record (History with the Job's detail); Request cancellation for a queued or active Job whose outcome is known (the macOS `canCancel` rule) after a confirmation dialog; "Cancellation requested…" or "Cancellation was not confirmed · unavailable(code): …" (the macOS strings) and the state read back; a terminal Job's `job.result`: Artifacts, verified, cleanup items |
| History detail | the macOS evidence section (`job.evidence`): status, provider, Catalog digest, binding, authority and its reference, terminal state, mode, effect, first evidence, the step kinds (or "Not reported"), blockers and missing Artifacts |
| Settings → Storage | unchanged code; it now shows the real Session root and usage |
| ArkDeck.ClientKit | a pipe whose every instance is busy (`ERROR_PIPE_BUSY`) is waited for within the call budget (`WaitNamedPipe`), as the Rust client's `connect_verified` does. Found by the real-daemon test: the App reads a page and the Job Inspector at once, and the second open met a busy pipe and was reported as the daemon being unavailable. This is also the likely cause of the unexplained failure recorded in `winui-settings-a11y-run.md` |

Strings: +16 macOS entries (`jobInspector.action.cancel|openRecord`, `jobInspector.cancel.*`,
`history.detail.evidence`, `history.evidence.*`, `history.value.notReported`,
`settings.common.cancel`; values unchanged) and +38 Windows-only. The App's writes now also
include `job.cancel` and the Session catalog's pin, unpin, cleanup and export — each confirmed or
generation-guarded; `TheAppHoldsNoRuntimeSemantics` names exactly these and still forbids
submitting, running or reconciling Jobs, adoption, device names, Artifact export/import, storage
policy and root, tool and HDC writes.

Scripted transport: the development-root scenario now answers as the daemon with the Job and
Session owners (table above); `jobs` gains a queued Job that stays queued until cancelled, the
terminal Jobs' `job.result`/`job.evidence`, and a Session catalog.

## Accessibility (the #2383 pass carried onto the new surfaces)

- Tab walk: Sessions (with a Session selected) and the Job Inspector with a queued Job selected
  join the pages whose every action must be a Tab stop in reading order, retraced by Shift+Tab.
- Access key Alt+N on Sessions (unique with O, D, H, S).
- Escape closes the cancellation confirmation (nothing cancelled) and the cleanup preview
  (nothing removed), besides the rename and Artifact export dialogs.
- 225 % text: Sessions (list and detail, and the foundation's refusal) and a failed Job's History
  detail with its evidence join the layout states; nothing runs past the page.
- UIA snapshots: Sessions over the recorded catalog and over the foundation, the Job Inspector
  with a queued and with a terminal Job, the History evidence section; both languages.

## Checks on the reference host

| Check | Result |
| --- | --- |
| generator `--check` ×3 | exit 0 |
| `dotnet build windows/ArkDeck.Windows.slnx -c Release` | exit 0, 0 warnings |
| `dotnet test` (lane default) | App.Tests 49 passed; ClientKit.Tests 32 passed, 1 skipped; App.UITests 49 skipped |
| `dotnet test` with `ARKDECK_APP_UITESTS=1`, the daemon above, `ARKDECK_DEV_SIGNER_THUMBPRINT` exported (before merging `main`) | App.Tests 49, ClientKit.Tests 33, App.UITests 47 passed, 2 inconclusive (`KeyboardFocusIsVisible`: workstation locked; `TheInstalledAppConnectsToTheDaemonTheCliStarted`: runs only under `package-rc.ps1 -Smoke`). An earlier full run had `EscapeClosesEveryDialog` fail once (passed alone twice); the Escape step now waits until the dialog's buttons exist before posting the key and repeats it once, saying so, if the dialog is still open after 3 s |
| after merging `main` (`c7fa14cb`) and rebuilding the daemon (SHA-256 `cf87d6c6…13ad`) | App.Tests 49; ClientKit.Tests 33 (end-to-end included); `RealDaemonTests` + `SurfaceFlowTests` 8/8 |
| `test_plan`, `test_agent_pr_workflow` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check` | exit 0, exit 0 |

Real daemon (`RealDaemonTests.SessionsArePinnedAndCleanedUpByTheRealRuntime`, 3 of 3 runs after the
ClientKit fix): the App lists the two recorded Sessions, pins one ("Pinned: retention cleanup
never removes it."), and after a policy set over the pipe the cleanup preview reads "Removes 1
Sessions and reclaims 7013 bytes (from 20599 bytes to 13586 bytes). Pinned Sessions are kept.";
confirmed, "Removed 1 Sessions, reclaimed 7013 bytes." and the Session's directory is gone from
the disk while the pinned one's manifest stays; the Job Inspector shows the empty Job store; a
cancellation of an unknown Job is `notFound`. The earlier real-daemon tests now meet the Job and
Session owners over the root: History shows the empty Job store, Settings → Storage the root's
`sessions` path and policy, Settings → Trace the answered Trace cache.

## Not done here, and why

1. **Export through the App against the real daemon**: the folder picker is a system dialog the
   UIA tests do not drive; the export path is covered by App.Tests over the scripted transport and
   by M1's CLI and process tests against the real daemon.
2. **A real Job cancelled or read from the App**: needs a Job admitted in process (above).
3. **Narrator by ear, real key strokes, the system high-contrast themes and 225 % text**: as in
   `winui-settings-a11y-run.md`.
4. The 38 new Windows-only strings' Chinese values want the maintainer's review.

CI: to be recorded by the PR's hosted run; not verified here.
