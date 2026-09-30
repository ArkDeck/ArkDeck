# TASK-XPA-020 — WinUI agent executions, human actions and Imports, 2026-09-30

- Task: TASK-XPA-020, client lane slice X3d (WM5 of `docs/design/cross-platform/windows-phase-agent-prompt.md`):
  the Windows client over the agent execution and human-action owners (TASK-XPA-005 S1, #2391,
  with the contract widened by #2389) and the Import owner (TASK-XPA-008 H3).
- Base: branch `agent/xpa-020-winui-agent-import-20260930`, cut from `origin/main` and written with
  #2391, #2389, #2394, #2397 and #2405 merged in as they landed; pushed as one commit on `main`
  `70dcd341`. Nothing is force-pushed.
- Host: the Windows 11 x64 reference host, non-elevated; .NET SDK 10.0.401, Windows App SDK 2.5.1,
  MSTest 4.4.1, FlaUI.UIA3 5.0.0; `ARKDECK_DEV_SIGNER_THUMBPRINT` exported in the gate. No system
  setting changed; no package registered; no device, `hdc` or DAYU200. Only the App instances and
  daemon copies the tests and probes launched ran; none was left running.

Host evidence for the client, not device, platform or Narrator-by-ear acceptance.

## What the daemon answers (measured)

Agent executions and human actions: the daemon of `main` (#2391, #2389, #2394, #2397; SHA-256
`93586657…886c`), over a development
root whose owner-only `agent-executions` and `targets-state` (created by a first start) received
the recorded Swift executions of `rust/tests/fixtures/agent-human-action` (their labelled
identities read as valid ones, as `windows_reconcile_agent_process.rs` lays them down) and the
adopted Target:

| Method | Answer |
| --- | --- |
| `agent.list` | the four executions: `har-ambiguous` `waitingForHuman` (generation 3), `har-connect` `completed`, `har-trust` `abandoned`, `har-unproven` `orchestrating` |
| `human-action.list`, `show` | the three recorded actions; only `<har-3>` (`ambiguousIdentity`, `human.confirmDeviceIdentity`) is `waiting`, with `selectionSchema` `{type: string, enum: [candidate-…1, candidate-…2]}` and `choices` naming the candidate keys `aaaa…`, `bbbb…` |
| `agent.status` | as listed, with the action; `har-connect` answers `internalError` ("execution resource could not be read or advanced") because its Job is not in this root |
| `agent.resume` without a selection | `invalidInput`, "selection must be an opaque value from this action's schema" |
| `agent.resume` with a value of the enum | `humanActionExpired`, "the durable orchestration deadline has expired" (the recorded deadline is 2026-09-14); the execution ends `budgetExpired`, `orchestrationBudgetExpired`, generation 4 |
| `agent.abandon` | with a stale generation `resourceConflict`, "execution generation changed"; with the read one, `abandoned` |
| unknown execution or action | `resourceNotFound` (`preAdmission`) |
| the private-endpoint foundation (no state root) | `agent.*`, `human-action.*`: `operationUnavailable`, "AgentExecution owner is unavailable" (`preAdmission`) |

Imports: the same daemon (H3's Import owner, #2397; measured first on H3's local owner, then on
`main`, with the same answers), over a development root holding the same adopted Target:

| Method | Answer |
| --- | --- |
| `artifact.import.begin` | `inProgress`, generation 1, `maximumChunkBytes` 2 097 152 |
| `append` ×n, `commit` of the recorded `fixture.hap` | `committed`, generation 2, receipt with `mediaType` `application/vnd.openharmony.hap`, privacy `standard` |
| `commit` of a `.hap` that is not a ZIP container | `invalidInput`, "Import is not a ZIP-based HAP/HSP container"; the Import stays `inProgress` |
| `commit` of a flash bundle | `operationUnavailable`, "This Import kind's publication validator is not configured" (`importOwner`); the Import stays `inProgress` |
| `abort` | `aborted`, generation 2 |
| `release`, and the same release again | `released` (generation 3, retention 7 days); the repeat answers the same release |
| `artifact.import.list` without the owner (today's foundation and the development root before H3) | `operationUnavailable`, "Import owner services are unavailable" (`importOwner`) |

## What was built

| Surface | Content |
| --- | --- |
| Agents (Records, Alt+A) | "Waiting for you": the waiting human actions (`human-action.list`); the agent executions (every `agent.list` page); an execution's `agent.status` facts (operation, state, generation, Job, Target, deadline, last observed, next action, failure, an unknown outcome); its waiting action with the macOS "Human action is required" heading and guidance, category, what to do and expiry; a pick-a-device action's values as a radio group (`RadioButtons`, header "Choose one", one Tab stop, arrow keys between the values) built from the `selectionSchema` enum and named by the candidate keys; Resume (`agent.resume` with the resume reference for an execution's action, `human-action.resume` otherwise; a value outside the enum cannot be sent, and Resume without a choice says "Choose one of the listed values first." instead of being disabled); Abandon… for a non-terminal execution after a confirmation, guarded by the generation read; results in a polite live region. Starting an agent stays in the CLI |
| Imports (Records, Alt+I) | New Import: kind (HAP, native library, workspace patch, flash bundle), the adopted Target (`target.list`), Choose file… (the Windows App SDK `FileOpenPicker`, filtered to the kind's types), Import; the macOS intent rules are checked before anything is sent; the upload (`ImportUploader`, the macOS `RuntimeAppArtifactUpload`: the file held open without write sharing, measured and hashed, then `begin`, 512 KiB `append` chunks each with its SHA-256 and the Runtime's offset checked, `commit`) shows a progress bar with "Sent … of …" (announced about every quarter) and Cancel, which aborts the partial Import; a failure before the commit aborts too, a lost commit reply is left alone. The Imports (`artifact.import.list`) and one Import's `inspect` (kind, state, size, SHA-256, Target, generation, created, and the receipt's Artifact, digest, media type, privacy); Release… for a committed Import after a confirmation, guarded by its generation |

Strings: +2 macOS entries (`jobRecovery.humanRequired.title|guidance`, values unchanged) and +81
Windows-only. The App's writes now also include `agent.resume`, `agent.abandon`,
`human-action.resume` and `artifact.import.begin|append|commit|abort|release`, named only in
`Agents.cs`, `Imports.cs` and the scripted daemon; `TheAppHoldsNoRuntimeSemantics` now also forbids
`agent.run` and `agent.chat`.

Scripted transport: `jobs` answers from the recorded agent-human-action exchanges (the connect and
pick-a-device executions waiting, a completed one; resume checks the value against the schema and
answers the recorded `connect.resume` shape) and runs an Import owner over the fixture Target
(begin, bounded appends checked by offset, count and digest, a HAP's ZIP check, commit, the flash
bundle refusal, abort, list, inspect, idempotent release). `foundation` answers as the
private-endpoint daemon measured above; the development root answers empty agent and
human-action pages.

## Accessibility (the #2383 pass carried onto the new surfaces)

- Tab walk: Agents with the pick-a-device action open and Imports with an Import selected join the
  pages whose every action must be a Tab stop in reading order, retraced by Shift+Tab.
- Access keys Alt+A (Agents) and Alt+I (Imports), unique with O, D, H, N, S.
- Escape closes the abandon confirmation (nothing abandoned) and the release confirmation (nothing
  released).
- 225 % text: Agents (with the action open, and the foundation's refusal) and Imports (with an
  Import, and the foundation's refusal) join the layout states; nothing runs past the page.
- UIA snapshots: Agents over the recorded executions with the action open (radio buttons named by
  the candidate keys, the live status), Agents over the foundation, Imports over the fixture
  Import, Imports over the foundation; both languages.
- The upload's progress bar is named "Upload progress" and its value line is a polite live region.

## Checks on the reference host

| Check | Result |
| --- | --- |
| generator `--check` ×4 (ClientKit, strings, tokens, icons) | exit 0 (423 strings: 188 shared, 235 Windows-only) |
| `dotnet build windows/ArkDeck.Windows.slnx -c Release` | exit 0, 0 warnings |
| `dotnet test` (lane default) | App.Tests 57 passed; ClientKit.Tests 32 passed, 1 skipped (end-to-end needs the daemon); App.UITests skipped |
| `dotnet test` with `ARKDECK_APP_UITESTS=1`, `ARKDECK_DEV_SIGNER_THUMBPRINT` exported and the daemon above (`ARKDECK_CLIENTKIT_DAEMON`) | App.Tests 57, ClientKit.Tests 33 (end-to-end included) and App.UITests 58 passed; 2 inconclusive (`KeyboardFocusIsVisible`: workstation locked; `TheInstalledAppConnectsToTheDaemonTheCliStarted`: runs only under `package-rc.ps1 -Smoke`) |
| `PYTHONUTF8=1 python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK (67) |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check` | 0 errors, 0 warnings; clean |

Real daemon, both tests run (not skipped), with every earlier real-daemon test:

- `RealDaemonTests.AgentExecutionsAreResumedAndAbandonedThroughTheRealRuntime`: the App lists the
  four recorded executions and the one waiting action; opening it shows exactly two radio buttons,
  "aaaa…" and "bbbb…"; Resume without a choice says so; with "bbbb…" chosen the Runtime answers
  "The Runtime did not resume · unavailable(humanActionExpired): the durable orchestration
  deadline has expired", the row reads `budgetExpired`, the action leaves the waiting list and the
  Runtime's record on disk is `budgetExpired`. The abandoned execution offers no Abandon; the
  orchestrating one is abandoned after "The Runtime stops agent execution har-unproven (generation
  2). It cannot be resumed afterwards.", and its record on disk is `abandoned`.
- `RealDaemonTests.AFileIsImportedAndReleasedByTheRealRuntime`: the recorded `fixture.hap` is chosen
  in the system file dialog (its file name box and Open driven through UIA), imported ("Imported
  fixture.hap as Artifact ART-…"), inspected (`committed`, its SHA-256, `application/vnd.openharmony.hap`)
  and released (`released`); a flash bundle is sent and refused ("Import failed ·
  unavailable(operationUnavailable): This Import kind's publication validator is not configured");
  the Runtime's list then holds `fixture.hap` released and `images.tar.gz` in progress.

The scripted flows (`AgentImportFlowTests`) drive the same system file dialog: a 1.2 MB HAP is sent
in three verified chunks, committed and released, and the flash bundle refused.

## Not done here, and why

1. **A resume that the Runtime accepts, against the real daemon**: the recorded executions' deadline
   has passed, and a fresh execution needs the HDC tuple (gated), so the real Runtime can only
   answer the expiry; the accepted resume is covered over the scripted transport with the recorded
   `connect.resume` answer.
2. **Cancelling an upload in the App against the real daemon**: a local upload finishes before a
   UIA Cancel lands; the abort after a cancellation is covered by App.Tests over the scripted
   transport (and `abort` was measured on the real owner).
3. **Narrator by ear, real key strokes, the system high-contrast themes and 225 % text**: as in
   `winui-settings-a11y-run.md`. `KeyboardFocusIsVisible` stays inconclusive while the workstation
   is locked.
4. The 81 new Windows-only strings' Chinese values want the maintainer's review.
5. A probe of the default start (no `ARKDECK_ENDPOINT`, no development root) during this slice
   created the account state root `%LOCALAPPDATA%\ArkDeck\Agentd` (empty stores) on this host; it
   was not there before. Removing it was not permitted from the session, so it is left for the
   maintainer. Every later probe used a development root or a private endpoint.

CI: to be recorded by the PR's hosted run; not verified here.
