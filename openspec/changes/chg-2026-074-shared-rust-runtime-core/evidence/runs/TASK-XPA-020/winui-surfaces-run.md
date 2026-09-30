# TASK-XPA-020 — WinUI surfaces on the Windows daemon's owners, 2026-09-30

- Task: TASK-XPA-020, client lane slice X3 (WM5 of `docs/design/cross-platform/windows-phase-agent-prompt.md`):
  the next Windows client surfaces the Windows daemon can serve today, on the TASK-XPA-007
  skeleton — adopted Targets and their Runtime display names (Device), the Job detail with its
  Artifacts, their export and the Trace inspection (History).
- Base: written on the WinUI skeleton (PR #2365, head `f29b3ac4`) and, once #2365 merged, put on
  `main` `5a2a1602`; every check below was rerun there.
- Host: the Windows 11 x64 reference host, non-elevated, .NET SDK 10.0.401, Windows App SDK
  2.5.1, MSTest 4.4.1, FlaUI.UIA3 5.0.0. Nothing installed beyond NuGet restores into
  `D:\nuget\packages`; no system setting changed; no package registered; no device, `hdc` or
  DAYU200 involved. The only processes started were the App instances and daemon copies the
  tests launched; none was left running and every temporary directory was removed.

This is host evidence for the client surfaces, not device or platform acceptance, and not
Narrator-by-ear acceptance.

## Which surfaces, and why these

The Windows daemon on `origin/main` (`65c4ba33`) composes, over a state root, only the Target
owners (#2350). Measured with that daemon (`cargo build -p arkdeck-agentd --locked`, SHA-256
`e5cd2ae9…3039`) over a development root seeded with the Swift adoption oracle's `targets.json`:

| Method | Answer on Windows today |
| --- | --- |
| `target.list`, `target.show`, `target.availability` | the oracle's Target (`TGT-3ba3f5f43b92`); availability: binding `ready`, presence `unresolved (device_observation_unavailable)`, profile `unresolved (profile_resolver_unavailable)`, tool `absent (runtime_tool_unavailable)`, 30 operations `unavailable (provider_not_registered)`, scope `host` |
| `target.display-name.set` / `clear` | recorded, generation-guarded (a stale generation is `resourceConflict`, phase `targetDisplayNameOwner`, 0 dispatch); a blank name `invalidInput`; the Runtime accepts 65 characters and keeps inner whitespace as given |
| `device.observations` | `rejected`, `hdc.notConfigured` |
| `job.*` | `rejected`, "The Job owner is not configured" |
| `artifact.list` (and the other Artifact methods) | `operationUnavailable`, "Artifact owner is not configured", phase `artifactOwner`, 0 dispatch |
| `trace.inspect` | `operationUnavailable`, "Trace inspection is unavailable", phase `traceInspectionOwner` (the Swift oracle's bytes, #2360) |
| the private-endpoint foundation, `target.*` | `internalError`, "Target owner is not configured" |

So Device (Targets) is served in full; History detail, Artifact export and Trace inspection are
built against the method contracts and the macOS behaviour, shown as refusals on today's daemon,
and exercised with scripted daemons until the Job store (#2361) and Artifact read/export (#2356)
owners land together. Import upload (#2357) is a host-store port only — no daemon composes it on
Windows — so no Import surface was built (see Limits).

## What was built

| Path | Content |
| --- | --- |
| `windows/App.Core/Presentation/Targets.cs` | `target.list/show/availability` and display-name projections; `DisplayName.Normalize`, the macOS rename rule (`DeviceWorkspace.normalizedDisplayName`: whitespace runs collapsed, 1–64 user-perceived characters) |
| `windows/App.Core/Presentation/Artifacts.cs` | `artifact.list` rows (owner checked, digest a SHA-256, a published row has one) and pages; the raw-Trace rule of macOS `TracePublishedArtifactPolicy.selectRawTrace`; the `trace.inspect` projection |
| `windows/App.Core/Presentation/ArtifactExport.cs` | the macOS export (`RuntimeJobDetailXPCProvider.exportArtifact`): 256 KiB `artifact.read` chunks, each checked as the CLI's `validate_artifact_read` checks it (Artifact and digest, offset asked for, byte count, EOF exactly at the total, no empty non-terminal chunk), written to a staging file beside the destination, SHA-256 of all bytes equal to the digest before the staging file replaces the destination (never a directory or reparse point); a sensitive Artifact only with the person's consent; the destination is never sent to the Runtime |
| `windows/App.Core/Presentation/Surfaces.cs` | loaders: Device reads `target.list` beside `device.observations`; `TargetAsync`, `RenameTargetAsync`, `ClearTargetNameAsync`; `HistoryDetailAsync` (`job.status` + every `artifact.list` page, a repeated cursor or more than 16 pages unreadable); `InspectTraceAsync`; the coverage CLI templates and their `--job` forms |
| `windows/App.Core/Testing/ScriptedDaemon.cs` | Foundation and the new `targets` scenario answer as the real daemon does (table above); `jobs` gains a Target, Artifacts (a published log, a `missing` row, a 300 000-byte sensitive raw Trace spanning two chunks, a config) and `artifact.read`; the new `inspector` scenario answers `trace.inspect` with the recorded ArkTrace projection |
| `windows/App/Pages/DevicePage.cs` | "Adopted targets" card: list, selected Target's facts and availability, Rename… (Fluent `ContentDialog`, the macOS strings, the refusal kept in the dialog as an assertive live region) and Clear name, results in a polite live region |
| `windows/App/Pages/HistoryPage.cs` | the macOS History detail: Job facts, Artifacts (`history.artifact.*` identifiers), Export… (the macOS preview dialog, the Windows App SDK `FileSavePicker`, progress, "Exported to …" with Show in File Explorer, or the failure with its CLI command), Inspect Trace, the export boundary and the deferred-viewer notes |
| `spec/ui-semantics/strings.json` | +30 macOS entries (`device.rename.*`, `device.action.rename`, `history.detail.*`, `history.artifacts.*`; values unchanged, `HistoryLocalizable` for the History keys) and +34 Windows-only `windows.*` entries (Targets, rename results, byte counts, export results, Trace inspection) |
| `spec/ui-semantics/surfaces.json` | optional `steps` (select / invoke before comparing); `device.foundation` gains the Target owner's absence, `device.jobs` the adopted Target; new `device.targets`, `history.jobs.traceDetail`, `history.jobs.failedDetail`, `history.inspector.trace` |
| `scripts/ci/plan.py`, `scripts/ci/test_plan.py` | the `windows` lane also selects on the two fixture directories its tests now read (`rust/tests/fixtures/trace-inspect/`, `rust/tests/fixtures/target-adoption/`) |

No control is disabled: an Artifact that is not published has no Export… (its status says
`missing`), a Target without a name has no Clear name, and every read without data shows
`unavailable(reasonCode)` with its CLI command and a working copy action. The App's only write
is the Target display name; `TheAppHoldsNoRuntimeSemantics` now allows exactly
`target.display-name.set|clear`, only in the loader, and still forbids Job, adoption, device
display name, Artifact export/import and Trace cache writes.

Design choice: the macOS App keeps device names in its own `UserDefaults`; on Windows the name
is the Runtime's (`target.display-name.*`, coverage `app.device.rename` equivalent command), so
the CLI and the App show one name. The macOS input rule and message are kept. Accepted on
2026-09-30 by the phase lead as a delegated minor decision (no Requirement, AC or safety
invariant changes; the macOS App is unchanged).

## Checks on the reference host

| Check | Result |
| --- | --- |
| `generate-clientkit.py --check`, `generate-ui-strings.py --check`, `generate-xaml-tokens.py --check` | exit 0 (105 methods; 196 strings, 129 shared with values unchanged, 67 Windows-only; tokens) |
| `dotnet build windows/ArkDeck.Windows.slnx -c Release` | exit 0, 0 warnings |
| `dotnet test … --no-build` (lane default) | App.Tests 37 passed; ClientKit.Tests 31 passed, 1 skipped; App.UITests 19 skipped |
| same with `ARKDECK_APP_UITESTS=1`, `ARKDECK_CLIENTKIT_DAEMON` = the daemon above | 88 passed, 0 skipped (App.Tests 37, ClientKit.Tests 32, App.UITests 19) |
| `PYTHONUTF8=1 python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK (66) |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check` | see the commit |

**App.Tests (+16):** the development root's Target without an HDC; a rename guarded by the
generation (stale → `resourceConflict`, nothing overwritten) and a clear; the macOS rename
rule (whitespace, 64/65 characters, grapheme clusters); the foundation's absent owners; a Job's
Artifacts as listed; the Trace refusal and the inspector's facts; every accepted recorded
Trace inspection (`rust/tests/fixtures/trace-inspect/projections.json`) readable; an export
writing exactly the bytes over two chunks, refusing a sensitive Artifact without consent, a
directory, an unpublished row, and replacing an existing file; five drifting-chunk cases
(digest, a byte, offset, EOF, total) each refused with the destination unchanged and no
staging file left; Artifact paging and a repeated cursor; a missing daemon reaching the banner
from every new surface.

**App.UITests (+7):** the four new snapshots and the two extended ones in en-US and zh-Hans
(steps through UIA SelectionItem/Invoke); `ATargetIsRenamedAndClearedThroughTheRuntime` (a
blank name keeps the dialog open with the assertive reason; "  Bench \t board " is saved as
"Bench board", announced, listed; cleared again); `TheExportPreviewNamesWhatWillBeWritten`
(no Export… on the `missing` row; the preview names the file, size, privacy and digest and
confirms a sensitive Artifact as such; Cancel reads nothing); and, against the real daemon,
`TheAppRenamesTheDevelopmentRootsTargetInTheRuntime`: a dev-signed copy
(`rust/scripts/windows-dev-identity.ps1 sign`) over a fresh development root seeded with the
oracle's `targets.json`, the App given only `ARKDECK_ENDPOINT` (the pipe the daemon announced),
`ARKDECK_DAEMON_PATH` and `ARKDECK_DAEMON_SIGNER_SHA256`. Observed: Device
`unavailable(rejected): hdc.notConfigured` beside the listed Target; connect key `aaaa…`;
presence `unresolved (device_observation_unavailable)`; tool `absent
(runtime_tool_unavailable)`; the dialog's rename recorded by the Runtime —
`target-display-names.json` `{"records":[{"generation":2,"name":"Bench board","targetID":"TGT-3ba3f5f43b92",…}],…}` —
then cleared; History `unavailable(rejected): The Job owner is not configured`; no disabled
button. The skeleton's real-daemon test still passes unchanged.

## Limits and what is left out

1. **No real Artifact round trip.** #2356 (Artifact read/export) refuses every Artifact
   method until a Job owner proves the Artifact's Job, and #2361 (Job store) is a separate open
   PR; neither is on `main`. The History detail, export and Trace inspection are exercised
   against scripted daemons (ClientKit's real codec and method schemas) and shown as the real
   daemon's refusals today. Re-run the real-daemon observation once both are merged.
2. **No Import surface.** The Windows import upload (#2357) is a host-store port; no Windows
   daemon composes the Import owner, and macOS has no standalone Import page (import is part of
   the Debug Apps flow of TASK-XPA-008). It belongs with the Debug surface.
3. **Trace viewer deferred** (decision 5): the page says so. `trace.inspect` with an inspector
   needs a Windows ArkTrace distribution, which does not exist (#2360).
4. **Debug, Flash, Viewer, Settings** are not started: their Windows owners are absent.
5. **The export's save dialog** (the Windows App SDK `FileSavePicker`) is not driven by the UIA
   tests; the export itself is covered in App.Tests over the scripted transport.
6. **Windows-only strings** (34 new) want the maintainer's review of the Chinese values.
7. Narrator by ear, keyboard-only path, high contrast and 225 % text were not exercised.

CI: to be recorded by the PR's hosted run (`windows-clientkit`, `swift` aggregate); not verified here.
